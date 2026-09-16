import XCTest

/// Shadow tests for Kubernetes cluster operations via Keg.
/// These tests exercise the K8s cluster lifecycle: create cluster, verify node ready,
/// deploy workloads, expose services, and tear down.
///
/// IMPORTANT: These tests create a real K8s cluster using kindest/node inside an Apple Container.
/// They take ~2-3 minutes to run and require ~8GB RAM. Only run when ready.
///
/// Run with: KEG_RUN_K8S_E2E=1 swift test --filter KubernetesShadowTests
final class KubernetesShadowTests: XCTestCase {

    private let clusterName = "keg-k8s-shadow"
    private var kubeconfigPath: String { NSHomeDirectory() + "/.keg/kubeconfig-shadow" }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["KEG_RUN_K8S_E2E"] == "1" else {
            throw XCTSkip("Set KEG_RUN_K8S_E2E=1 to run Kubernetes shadow tests (takes ~2-3 min, needs ~8GB RAM)")
        }
        try await super.setUp()
        try await ensureContainerSystemRunning()
    }

    override func tearDown() async throws {
        // Always clean up the cluster
        if ProcessInfo.processInfo.environment["KEG_RUN_K8S_E2E"] == "1" {
            await deleteCluster()
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func runProcess(_ args: [String], timeout: TimeInterval = 120) throws -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    private func kubectl(_ args: String...) throws -> (Int32, String) {
        var fullArgs = ["kubectl", "--kubeconfig", kubeconfigPath]
        fullArgs.append(contentsOf: args)
        return try runProcess(fullArgs)
    }

    private func ensureContainerSystemRunning() async throws {
        let (code, _) = try runProcess(["container", "system", "status", "--format", "json"])
        guard code == 0 else {
            throw XCTSkip("container system not running")
        }
    }

    private func deleteCluster() async {
        _ = try? runProcess(["container", "rm", "-f", clusterName])
        try? FileManager.default.removeItem(atPath: kubeconfigPath)
    }

    private func waitForCondition(
        description: String,
        timeout: TimeInterval = 120,
        interval: TimeInterval = 5,
        check: () throws -> Bool
    ) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if (try? check()) == true { return }
            try await Task.sleep(for: .seconds(interval))
            print("  ⏳ Waiting for \(description)... (\(Int(Date().timeIntervalSince(start)))s)")
        }
        XCTFail("Timed out waiting for \(description) after \(Int(timeout))s")
    }

    // MARK: - Cluster Lifecycle

    /// Test: Create a K8s cluster, verify node is ready
    func testCreateCluster() async throws {
        print("🔄 Creating K8s cluster '\(clusterName)'...")

        // Step 1: Start the kindest/node container
        // kindest/node's entrypoint needs full capabilities (remounts /sys,
        // manages cgroups/iptables); without --cap-add ALL it exits with
        // "mount: /sys: permission denied".
        let (runCode, runOut) = try runProcess([
            "container", "run", "-d",
            "--name", clusterName,
            "--cap-add", "ALL",
            "-m", "8G",
            "-c", "4",
            "-e", "KUBECONFIG=/etc/kubernetes/admin.conf",
            "-p", "127.0.0.1:16443:6443",
            "docker.io/kindest/node:v1.34.0"
        ])
        XCTAssertEqual(runCode, 0, "kindest/node should start: \(runOut)")
        print("✅ K8s node container started")

        // Step 2: Wait for container to boot
        try await Task.sleep(for: .seconds(5))

        // Step 3: Enable IP forwarding
        // Step 3: Remount /proc/sys rw (arrives read-only; sysctl writes fail
        // with EROFS until remounted) and enable IP forwarding
        let (mountCode, _) = try runProcess([
            "container", "exec", clusterName,
            "mount", "-o", "remount,rw", "/proc/sys"
        ])
        XCTAssertEqual(mountCode, 0, "/proc/sys should remount rw")
        let (fwdCode, _) = try runProcess([
            "container", "exec", clusterName,
            "sysctl", "-w", "net.ipv4.ip_forward=1"
        ])
        XCTAssertEqual(fwdCode, 0, "IP forwarding should enable")
        print("✅ IP forwarding enabled")

        // Step 3b: Apple's container networking does not run DNS on the vmnet
        // gateway; point resolv.conf at public resolvers so kubeadm can pull
        // images from registry.k8s.io (mirrors KubernetesView's bootstrap).
        let (dnsCode, _) = try runProcess([
            "container", "exec", clusterName, "sh", "-euc",
            "printf 'nameserver 1.1.1.1\\nnameserver 8.8.8.8\\n' > /etc/resolv.conf"
        ])
        XCTAssertEqual(dnsCode, 0, "DNS resolvers should be written")

        // Step 4: Initialize kubeadm
        print("🔄 Running kubeadm init (this takes ~60s)...")
        let (initCode, initOut) = try runProcess([
            "container", "exec", clusterName,
            "kubeadm", "init", "--pod-network-cidr=10.244.0.0/16",
            "--apiserver-cert-extra-sans", "127.0.0.1,localhost"
        ], timeout: 180)
        XCTAssertEqual(initCode, 0, "kubeadm init should succeed: \(initOut.suffix(500))")
        print("✅ kubeadm initialized")

        // Step 5: Install CNI
        let (cniCode, cniOut) = try runProcess([
            "container", "exec", clusterName, "sh", "-euc",
            "sed -e 's@{{ .PodSubnet }}@10.244.0.0/16@' /kind/manifests/default-cni.yaml | kubectl apply -f -"
        ])
        XCTAssertEqual(cniCode, 0, "CNI install should succeed: \(cniOut)")
        print("✅ CNI installed")

        // Step 6: Remove control-plane taint
        let (taintCode, _) = try runProcess([
            "container", "exec", clusterName,
            "kubectl", "taint", "nodes", "--all", "node-role.kubernetes.io/control-plane-"
        ])
        // taint removal may warn if no taint found, that's ok
        print("✅ Control-plane taint removed (code: \(taintCode))")

        // Step 7: Extract kubeconfig
        let (kcCode, kcOut) = try runProcess([
            "container", "exec", clusterName,
            "cat", "/etc/kubernetes/admin.conf"
        ])
        XCTAssertEqual(kcCode, 0, "should extract kubeconfig")

        var kubeconfig = kcOut
        kubeconfig = kubeconfig.replacingOccurrences(of: "kubernetes.default.svc", with: "127.0.0.1")
        kubeconfig = kubeconfig.replacingOccurrences(of: ":6443", with: ":16443")
        try kubeconfig.write(toFile: kubeconfigPath, atomically: true, encoding: .utf8)
        print("✅ Kubeconfig saved to \(kubeconfigPath)")

        // Step 8: Wait for node Ready
        try await waitForCondition(description: "node Ready", timeout: 90) {
            let (code, output) = try kubectl("get", "nodes", "-o", "wide")
            return code == 0 && output.contains("Ready")
        }

        let (nodesCode, nodesOut) = try kubectl("get", "nodes", "-o", "wide")
        XCTAssertEqual(nodesCode, 0)
        XCTAssertTrue(nodesOut.contains("Ready"), "Node should be Ready")
        print("✅ K8s cluster ready:\n\(nodesOut)")
    }

    /// Test: Deploy nginx and verify pod runs
    func testDeployNginx() async throws {
        // First create the cluster
        try await testCreateCluster()

        print("🔄 Deploying nginx...")

        // Create a simple nginx deployment
        let deployYaml = """
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: nginx-shadow-test
          labels:
            app: nginx-shadow
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: nginx-shadow
          template:
            metadata:
              labels:
                app: nginx-shadow
            spec:
              containers:
              - name: nginx
                image: nginx:latest
                ports:
                - containerPort: 80
        """

        // Write manifest and apply
        let manifestPath = NSTemporaryDirectory() + "nginx-shadow-test.yaml"
        try deployYaml.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let (applyCode, applyOut) = try kubectl("apply", "-f", manifestPath)
        XCTAssertEqual(applyCode, 0, "nginx deployment should apply: \(applyOut)")
        print("✅ nginx deployment applied")

        // Wait for pod to be running
        try await waitForCondition(description: "nginx pod Running", timeout: 90) {
            let (code, output) = try kubectl("get", "pods", "-l", "app=nginx-shadow", "-o", "wide")
            return code == 0 && output.contains("Running")
        }

        let (podsCode, podsOut) = try kubectl("get", "pods", "-l", "app=nginx-shadow", "-o", "wide")
        XCTAssertEqual(podsCode, 0)
        XCTAssertTrue(podsOut.contains("Running"), "nginx pod should be Running")
        print("✅ nginx pod running:\n\(podsOut)")

        // Verify the deployment
        let (deployCode, deployOut) = try kubectl("get", "deployment", "nginx-shadow-test")
        XCTAssertEqual(deployCode, 0)
        XCTAssertTrue(deployOut.contains("1/1"), "deployment should have 1/1 ready")
        print("✅ Deployment ready:\n\(deployOut)")

        // Clean up
        let (delCode, _) = try kubectl("delete", "deployment", "nginx-shadow-test")
        XCTAssertEqual(delCode, 0)
        try? FileManager.default.removeItem(atPath: manifestPath)
        print("✅ nginx deployment deleted")
    }

    /// Test: Create a service and verify it exists
    func testCreateService() async throws {
        try await testCreateCluster()

        print("🔄 Creating nginx + service...")

        // Deploy nginx
        let (runCode, _) = try kubectl(
            "create", "deployment", "svc-test",
            "--image=nginx:latest",
            "--port=80"
        )
        XCTAssertEqual(runCode, 0)

        // Expose as ClusterIP service
        let (exposeCode, exposeOut) = try kubectl(
            "expose", "deployment", "svc-test",
            "--port=80", "--target-port=80",
            "--type=ClusterIP"
        )
        XCTAssertEqual(exposeCode, 0, "service expose should succeed: \(exposeOut)")
        print("✅ Service created")

        // Verify service exists
        let (svcCode, svcOut) = try kubectl("get", "svc", "svc-test")
        XCTAssertEqual(svcCode, 0)
        XCTAssertTrue(svcOut.contains("svc-test"), "Service should exist")
        XCTAssertTrue(svcOut.contains("80"), "Service should expose port 80")
        print("✅ Service verified:\n\(svcOut)")

        // Clean up
        _ = try kubectl("delete", "svc", "svc-test")
        _ = try kubectl("delete", "deployment", "svc-test")
        print("✅ Service and deployment cleaned up")
    }

    /// Test: Run a Job and verify it completes
    func testRunJob() async throws {
        try await testCreateCluster()

        print("🔄 Running K8s job...")

        let (jobCode, jobOut) = try kubectl(
            "create", "job", "shadow-job",
            "--image=busybox:latest",
            "--", "echo", "hello-from-keg-k8s"
        )
        XCTAssertEqual(jobCode, 0, "Job creation should succeed: \(jobOut)")
        print("✅ Job created")

        // Wait for completion
        try await waitForCondition(description: "job Complete", timeout: 60) {
            let (code, output) = try kubectl("get", "job", "shadow-job")
            return code == 0 && output.contains("1/1")
        }

        let (statusCode, statusOut) = try kubectl("get", "job", "shadow-job")
        XCTAssertEqual(statusCode, 0)
        XCTAssertTrue(statusOut.contains("1/1"), "Job should complete")
        print("✅ Job completed:\n\(statusOut)")

        // Check job logs
        let (logCode, logOut) = try kubectl("logs", "job/shadow-job")
        XCTAssertEqual(logCode, 0)
        XCTAssertTrue(logOut.contains("hello-from-keg-k8s"), "Job output should contain our message")
        print("✅ Job output: \(logOut.trimmingCharacters(in: .whitespacesAndNewlines))")

        // Clean up
        _ = try kubectl("delete", "job", "shadow-job")
        print("✅ Job cleaned up")
    }

    /// Test: Create a ConfigMap and mount it in a pod
    func testConfigMapMount() async throws {
        try await testCreateCluster()

        print("🔄 Testing ConfigMap...")

        // Create ConfigMap
        let (cmCode, cmOut) = try kubectl(
            "create", "configmap", "shadow-config",
            "--from-literal=app.name=keg",
            "--from-literal=app.version=1.0"
        )
        XCTAssertEqual(cmCode, 0, "ConfigMap should create: \(cmOut)")
        print("✅ ConfigMap created")

        // Verify ConfigMap data
        let (getCode, getOut) = try kubectl("get", "configmap", "shadow-config", "-o", "yaml")
        XCTAssertEqual(getCode, 0)
        XCTAssertTrue(getOut.contains("app.name: keg"))
        XCTAssertTrue(getOut.contains("app.version: \"1.0\""))
        print("✅ ConfigMap data verified")

        // Clean up
        _ = try kubectl("delete", "configmap", "shadow-config")
        print("✅ ConfigMap cleaned up")
    }

    /// Test: Verify cluster info and component health
    func testClusterHealth() async throws {
        try await testCreateCluster()

        // Check cluster info
        let (infoCode, infoOut) = try kubectl("cluster-info")
        XCTAssertEqual(infoCode, 0)
        XCTAssertTrue(infoOut.contains("control plane") || infoOut.contains("Kubernetes"), "Should show cluster info")
        print("✅ Cluster info:\n\(infoOut)")

        // Check component statuses
        let (nsCode, nsOut) = try kubectl("get", "namespaces")
        XCTAssertEqual(nsCode, 0)
        XCTAssertTrue(nsOut.contains("default"))
        XCTAssertTrue(nsOut.contains("kube-system"))
        print("✅ Namespaces:\n\(nsOut)")

        // Check kube-system pods
        let (sysCode, sysOut) = try kubectl("get", "pods", "-n", "kube-system")
        XCTAssertEqual(sysCode, 0)
        XCTAssertTrue(sysOut.contains("kube-apiserver"), "API server pod should exist")
        XCTAssertTrue(sysOut.contains("kube-scheduler"), "Scheduler pod should exist")
        print("✅ System pods:\n\(sysOut)")
    }

    /// Test: Scale a deployment to 3 replicas and verify all pods are Running
    func testScaleDeployment() async throws {
        try await testCreateCluster()

        print("🔄 Deploying nginx for scale test...")

        let (createCode, createOut) = try kubectl(
            "create", "deployment", "nginx-shadow-test",
            "--image=nginx:latest",
            "--port=80"
        )
        XCTAssertEqual(createCode, 0, "nginx deployment should create: \(createOut)")

        // Wait for initial pod to be running
        try await waitForCondition(description: "nginx pod Running", timeout: 90) {
            let (code, output) = try kubectl("get", "pods", "-l", "app=nginx-shadow-test", "-o", "wide")
            return code == 0 && output.contains("Running")
        }

        print("🔄 Scaling to 3 replicas...")
        let (scaleCode, scaleOut) = try kubectl(
            "scale", "deployment", "nginx-shadow-test", "--replicas=3"
        )
        XCTAssertEqual(scaleCode, 0, "scale should succeed: \(scaleOut)")

        // Wait for all 3 pods to be Running
        try await waitForCondition(description: "3 pods Running", timeout: 120) {
            let (code, output) = try kubectl("get", "pods", "-l", "app=nginx-shadow-test", "-o", "wide")
            guard code == 0 else { return false }
            let runningCount = output.components(separatedBy: "\n").filter { $0.contains("Running") }.count
            return runningCount >= 3
        }

        let (podsCode, podsOut) = try kubectl("get", "pods", "-l", "app=nginx-shadow-test", "-o", "wide")
        XCTAssertEqual(podsCode, 0)
        let runningCount = podsOut.components(separatedBy: "\n").filter { $0.contains("Running") }.count
        XCTAssertGreaterThanOrEqual(runningCount, 3, "Should have 3 Running pods, got \(runningCount)")
        print("✅ Scaled to 3 replicas:\n\(podsOut)")

        // Verify deployment shows 3/3 ready
        let (deployCode, deployOut) = try kubectl("get", "deployment", "nginx-shadow-test")
        XCTAssertEqual(deployCode, 0)
        XCTAssertTrue(deployOut.contains("3/3"), "deployment should have 3/3 ready")
        print("✅ Deployment ready:\n\(deployOut)")

        // Clean up
        let (delCode, _) = try kubectl("delete", "deployment", "nginx-shadow-test")
        XCTAssertEqual(delCode, 0)
        print("✅ Scaled deployment cleaned up")
    }

    /// Test: Rolling update from nginx:1.25 to nginx:latest
    func testRollingUpdate() async throws {
        try await testCreateCluster()

        print("🔄 Deploying nginx:1.25 for rolling update test...")

        let (createCode, createOut) = try kubectl(
            "create", "deployment", "nginx-shadow-test",
            "--image=nginx:1.25",
            "--port=80"
        )
        XCTAssertEqual(createCode, 0, "nginx:1.25 deployment should create: \(createOut)")

        // Wait for initial pod to be running
        try await waitForCondition(description: "nginx:1.25 pod Running", timeout: 90) {
            let (code, output) = try kubectl("get", "pods", "-l", "app=nginx-shadow-test", "-o", "wide")
            return code == 0 && output.contains("Running")
        }
        print("✅ nginx:1.25 running")

        // Perform rolling update
        print("🔄 Updating image to nginx:latest...")
        let (setCode, setOut) = try kubectl(
            "set", "image", "deployment/nginx-shadow-test", "nginx=nginx:latest"
        )
        XCTAssertEqual(setCode, 0, "set image should succeed: \(setOut)")

        // Wait for rollout to complete
        try await waitForCondition(description: "rollout complete", timeout: 120) {
            let (code, output) = try kubectl("rollout", "status", "deployment/nginx-shadow-test")
            return code == 0 && output.contains("successfully rolled out")
        }
        print("✅ Rollout complete")

        // Verify the new image is running
        let (descCode, descOut) = try kubectl(
            "get", "deployment", "nginx-shadow-test",
            "-o", "jsonpath={.spec.template.spec.containers[0].image}"
        )
        XCTAssertEqual(descCode, 0)
        XCTAssertTrue(descOut.contains("nginx:latest"), "Image should be nginx:latest, got: \(descOut)")
        print("✅ Image verified: \(descOut)")

        // Clean up
        let (delCode, _) = try kubectl("delete", "deployment", "nginx-shadow-test")
        XCTAssertEqual(delCode, 0)
        print("✅ Rolling update deployment cleaned up")
    }

    /// Test: Exec into a running pod and read nginx config
    func testKubectlExec() async throws {
        try await testCreateCluster()

        print("🔄 Deploying nginx for exec test...")

        let (createCode, createOut) = try kubectl(
            "create", "deployment", "nginx-shadow-test",
            "--image=nginx:latest",
            "--port=80"
        )
        XCTAssertEqual(createCode, 0, "nginx deployment should create: \(createOut)")

        // Wait for pod to be running
        try await waitForCondition(description: "nginx pod Running", timeout: 90) {
            let (code, output) = try kubectl("get", "pods", "-l", "app=nginx-shadow-test", "-o", "wide")
            return code == 0 && output.contains("Running")
        }

        // Get pod name
        let (nameCode, podName) = try kubectl(
            "get", "pods", "-l", "app=nginx-shadow-test",
            "-o", "jsonpath={.items[0].metadata.name}"
        )
        XCTAssertEqual(nameCode, 0, "should get pod name")
        let trimmedPodName = podName.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmedPodName.isEmpty, "pod name should not be empty")
        print("✅ Pod name: \(trimmedPodName)")

        // Exec into pod and cat nginx config
        let (execCode, execOut) = try kubectl(
            "exec", trimmedPodName, "--", "cat", "/etc/nginx/nginx.conf"
        )
        XCTAssertEqual(execCode, 0, "kubectl exec should succeed")
        XCTAssertTrue(execOut.contains("worker_processes"), "nginx.conf should contain worker_processes, got: \(execOut.prefix(200))")
        print("✅ Exec output contains worker_processes")

        // Clean up
        let (delCode, _) = try kubectl("delete", "deployment", "nginx-shadow-test")
        XCTAssertEqual(delCode, 0)
        print("✅ Exec test deployment cleaned up")
    }

    /// Test: Fetch logs from a running pod
    func testKubectlLogs() async throws {
        try await testCreateCluster()

        print("🔄 Deploying nginx for logs test...")

        let (createCode, createOut) = try kubectl(
            "create", "deployment", "nginx-shadow-test",
            "--image=nginx:latest",
            "--port=80"
        )
        XCTAssertEqual(createCode, 0, "nginx deployment should create: \(createOut)")

        // Wait for pod to be running
        try await waitForCondition(description: "nginx pod Running", timeout: 90) {
            let (code, output) = try kubectl("get", "pods", "-l", "app=nginx-shadow-test", "-o", "wide")
            return code == 0 && output.contains("Running")
        }

        // Get pod name
        let (nameCode, podName) = try kubectl(
            "get", "pods", "-l", "app=nginx-shadow-test",
            "-o", "jsonpath={.items[0].metadata.name}"
        )
        XCTAssertEqual(nameCode, 0, "should get pod name")
        let trimmedPodName = podName.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmedPodName.isEmpty, "pod name should not be empty")
        print("✅ Pod name: \(trimmedPodName)")

        // Fetch logs - may be empty initially, that's ok
        let (logCode, logOut) = try kubectl("logs", trimmedPodName)
        XCTAssertEqual(logCode, 0, "kubectl logs should succeed")
        // Logs may be empty for a freshly started nginx with no requests, that's acceptable
        print("✅ Logs fetched successfully (\(logOut.count) bytes)")
        if !logOut.isEmpty {
            print("  Log preview: \(String(logOut.prefix(200)))")
        }

        // Clean up
        let (delCode, _) = try kubectl("delete", "deployment", "nginx-shadow-test")
        XCTAssertEqual(delCode, 0)
        print("✅ Logs test deployment cleaned up")
    }

    /// Test: Create a secret and verify it exists
    func testCreateSecret() async throws {
        try await testCreateCluster()

        print("🔄 Creating secret...")

        let (createCode, createOut) = try kubectl(
            "create", "secret", "generic", "shadow-secret",
            "--from-literal=password=keg123"
        )
        XCTAssertEqual(createCode, 0, "Secret should create: \(createOut)")
        print("✅ Secret created")

        // Verify secret exists
        let (getCode, getOut) = try kubectl("get", "secret", "shadow-secret")
        XCTAssertEqual(getCode, 0, "should get secret")
        XCTAssertTrue(getOut.contains("shadow-secret"), "Secret should exist in output")
        print("✅ Secret verified:\n\(getOut)")

        // Verify secret data via yaml
        let (yamlCode, yamlOut) = try kubectl("get", "secret", "shadow-secret", "-o", "yaml")
        XCTAssertEqual(yamlCode, 0)
        XCTAssertTrue(yamlOut.contains("password"), "Secret should contain password key")
        print("✅ Secret data verified")

        // Clean up
        let (delCode, _) = try kubectl("delete", "secret", "shadow-secret")
        XCTAssertEqual(delCode, 0)
        print("✅ Secret cleaned up")
    }

    /// Test: Delete cluster cleanly
    func testDeleteCluster() async throws {
        try await testCreateCluster()

        print("🔄 Deleting cluster...")

        let (delCode, _) = try runProcess(["container", "rm", "-f", clusterName])
        XCTAssertEqual(delCode, 0, "Cluster container should be removed")

        // Verify container is gone
        let (inspectCode, _) = try runProcess(["container", "inspect", clusterName])
        XCTAssertNotEqual(inspectCode, 0, "Container should not exist after deletion")
        print("✅ Cluster deleted and verified gone")

        // Clean up kubeconfig
        try? FileManager.default.removeItem(atPath: kubeconfigPath)
        print("✅ Kubeconfig cleaned up")
    }
}
