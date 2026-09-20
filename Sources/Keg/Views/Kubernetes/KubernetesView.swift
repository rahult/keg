import SwiftUI

enum ClusterStatus: Equatable {
    case notCreated
    case creating
    case running
    case stopped
    case starting
    case stopping
    case error(String)

    var displayName: String {
        switch self {
        case .notCreated: return "Not Created"
        case .creating:   return "Creating…"
        case .running:    return "Running"
        case .stopped:    return "Stopped"
        case .starting:   return "Starting…"
        case .stopping:   return "Stopping…"
        case .error:      return "Error"
        }
    }

    var badgeKind: String {
        switch self {
        case .running:                       return "running"
        case .creating, .starting, .stopping: return "created"
        case .stopped, .notCreated, .error:   return "stopped"
        }
    }

    var isBusy: Bool {
        switch self {
        case .creating, .starting, .stopping: return true
        default: return false
        }
    }
}

@Observable
@MainActor
final class KubernetesVM {
    var clusterName = "keg-k8s"
    var clusterStatus: ClusterStatus = .notCreated
    var nodeImage = "docker.io/kindest/node:v1.34.0"
    var isCreating = false
    var isDeleting = false
    var output = ""
    var errorMessage: String?
    var kubeconfigPath: String?

    func createCluster() async {
        isCreating = true
        output = ""
        errorMessage = nil
        clusterStatus = .creating

        do {
            output += "Starting K8s node container...\n"
            // kindest/node's entrypoint remounts /sys, manipulates cgroups and
            // iptables — without elevated capabilities it dies immediately
            // with "mount: /sys: permission denied" (container CLI ≥ 1.x
            // defaults are restrictive).
            let (code, out) = try await runCLI([
                "container", "run", "-d",
                "--name", clusterName,
                "--cap-add", "ALL",
                "-m", "8G",
                "-c", "4",
                "-e", "KUBECONFIG=/etc/kubernetes/admin.conf",
                "-p", "127.0.0.1:6443:6443",
                nodeImage
            ])
            if code != 0 { throw K8sError.createFailed(out) }
            output += out + "\n"

            output += "Waiting for container to boot...\n"
            try await Task.sleep(for: .seconds(5))

            output += "Enabling IP forwarding...\n"
            // /proc/sys arrives read-only, so the sysctl write fails with
            // EROFS until it's remounted (sysctl(8) writes via the proc file).
            let _ = try await runCLI(["container", "exec", clusterName, "mount", "-o", "remount,rw", "/proc/sys"])
            let _ = try await runCLI(["container", "exec", clusterName, "sysctl", "-w", "net.ipv4.ip_forward=1"])

            // Apple's container networking does not run a DNS service on the vmnet
            // gateway, so the default /etc/resolv.conf (which points at that
            // gateway) fails to resolve `registry.k8s.io`, blocking kubeadm's
            // image pull. Overwrite with public resolvers before init.
            output += "Configuring DNS resolvers...\n"
            let _ = try await runCLI([
                "container", "exec", clusterName, "sh", "-euc",
                "printf 'nameserver 1.1.1.1\\nnameserver 8.8.8.8\\n' > /etc/resolv.conf"
            ])

            output += "Initializing Kubernetes (this takes ~60s)...\n"
            // `--apiserver-cert-extra-sans` adds `127.0.0.1` to the API server's
            // TLS cert so `kubectl` against the published `127.0.0.1:6443` port
            // passes TLS verification without `--insecure-skip-tls-verify`.
            let (initCode, initOut) = try await runCLI([
                "container", "exec", clusterName,
                "kubeadm", "init",
                "--pod-network-cidr=10.244.0.0/16",
                "--apiserver-cert-extra-sans", "127.0.0.1,localhost"
            ])
            output += initOut + "\n"
            if initCode != 0 { throw K8sError.createFailed(initOut) }

            output += "Installing CNI...\n"
            let (_, cniOut) = try await runCLI([
                "container", "exec", clusterName, "sh", "-euc",
                "sed -e 's@{{ .PodSubnet }}@10.244.0.0/16@' /kind/manifests/default-cni.yaml | kubectl apply -f -"
            ])
            output += cniOut + "\n"

            output += "Removing control-plane taint...\n"
            let _ = try await runCLI([
                "container", "exec", clusterName,
                "kubectl", "taint", "nodes", "--all", "node-role.kubernetes.io/control-plane-"
            ])

            output += "Extracting kubeconfig...\n"
            let kubeconfigDir = NSHomeDirectory() + "/.keg"
            try FileManager.default.createDirectory(atPath: kubeconfigDir, withIntermediateDirectories: true)
            let kcPath = kubeconfigDir + "/kubeconfig"
            let (kcCode, kcOut) = try await runCLI([
                "container", "exec", clusterName, "cat", "/etc/kubernetes/admin.conf"
            ])
            if kcCode == 0 {
                // The kubeconfig kubeadm emits points at the node's vmnet IP
                // (unreachable from macOS). Rewrite the server URL to the
                // published `127.0.0.1:6443` port so kubectl works from the host.
                let rewritten = Self.rewriteKubeconfigServer(kcOut, host: "127.0.0.1", port: 6443)
                try rewritten.write(toFile: kcPath, atomically: true, encoding: .utf8)
                kubeconfigPath = kcPath
            }

            clusterStatus = .running
            output += "\n✅ Cluster ready!\n"
            output += "export KUBECONFIG=\"\(kcPath)\"\n"
            output += "kubectl get nodes\n"
        } catch {
            errorMessage = error.localizedDescription
            clusterStatus = .error(error.localizedDescription)
        }
        isCreating = false
    }

    func stopCluster() async {
        clusterStatus = .stopping
        output += "Stopping cluster…\n"
        errorMessage = nil
        do {
            let (code, out) = try await runCLI(["container", "stop", clusterName])
            if code == 0 {
                clusterStatus = .stopped
                output += "✅ Cluster stopped\n"
            } else {
                errorMessage = out.isEmpty ? "Failed to stop cluster" : out
                clusterStatus = .running
            }
        } catch {
            errorMessage = error.localizedDescription
            clusterStatus = .running
        }
    }

    func startCluster() async {
        clusterStatus = .starting
        output += "Starting cluster…\n"
        errorMessage = nil
        do {
            let (code, out) = try await runCLI(["container", "start", clusterName])
            if code == 0 {
                output += "Waiting for API server…\n"
                if await waitForAPIServer() {
                    output += "✅ Cluster running\n"
                } else {
                    output += "⚠️ API server did not report ready within 60s — it may still be starting.\n"
                }
                clusterStatus = .running
            } else {
                errorMessage = out.isEmpty ? "Failed to start cluster" : out
                clusterStatus = .stopped
            }
        } catch {
            errorMessage = error.localizedDescription
            clusterStatus = .stopped
        }
    }

    /// Poll `kubectl get --raw /readyz` until the API server responds or we
    /// time out. Runs inside the node container so it doesn't depend on the
    /// host's kubeconfig being valid yet.
    /// Returns true when the API server reported ready before the deadline.
    private func waitForAPIServer(timeout: Duration = .seconds(60)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let (code, _) = try? await runCLI([
                "container", "exec", clusterName,
                "kubectl", "get", "--raw", "/readyz"
            ]), code == 0 {
                return true
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    func deleteCluster() async {
        isDeleting = true
        output = ""
        errorMessage = nil

        do {
            let (code, out) = try await runCLI(["container", "delete", "-f", clusterName])
            if code == 0 {
                if let kcPath = kubeconfigPath { try? FileManager.default.removeItem(atPath: kcPath) }
                kubeconfigPath = nil
                clusterStatus = .notCreated
                output = "Cluster deleted"
            } else {
                errorMessage = out.isEmpty ? "Failed to delete cluster" : out
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isDeleting = false
    }

    func checkClusterStatus() async {
        do {
            // `container ls` lists only running containers; `-a` includes stopped.
            // If the cluster appears in `-a` but not in the running list, it's stopped.
            let (runningCode, runningOut) = try await runCLI(["container", "ls", "--format", "json"])
            let (allCode, allOut) = try await runCLI(["container", "ls", "-a", "--format", "json"])
            guard runningCode == 0, allCode == 0 else { return }

            let isRunning = runningOut.contains("\"\(clusterName)\"")
            let existsAtAll = allOut.contains("\"\(clusterName)\"")

            if isRunning {
                clusterStatus = .running
            } else if existsAtAll {
                clusterStatus = .stopped
                return
            } else {
                clusterStatus = .notCreated
                return
            }

            let kcPath = NSHomeDirectory() + "/.keg/kubeconfig"
            if !FileManager.default.fileExists(atPath: kcPath) {
                // Cluster survived but kubeconfig was lost — re-extract so `kubectl` works.
                let (kcCode, kcOut) = try await runCLI([
                    "container", "exec", clusterName, "cat", "/etc/kubernetes/admin.conf"
                ])
                if kcCode == 0 {
                    let dir = (kcPath as NSString).deletingLastPathComponent
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    let content = Self.rewriteKubeconfigServer(kcOut, host: "127.0.0.1", port: 6443)
                    try? content.write(toFile: kcPath, atomically: true, encoding: .utf8)
                }
            }
            kubeconfigPath = kcPath
        } catch {
            // Status check is best-effort on launch; leave status unchanged
        }
    }

    /// Replace `server: https://<ip>:<port>` lines in a kubeconfig YAML with
    /// the given host/port so kubectl can reach the API server from the host.
    static func rewriteKubeconfigServer(_ kubeconfig: String, host: String, port: Int) -> String {
        let pattern = #"server:\s*https://[^\s]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return kubeconfig }
        let range = NSRange(kubeconfig.startIndex..., in: kubeconfig)
        return regex.stringByReplacingMatches(
            in: kubeconfig,
            range: range,
            withTemplate: "server: https://\(host):\(port)"
        )
    }

    private func runCLI(_ args: [String], timeout: Duration = .seconds(300)) async throws -> (Int32, String) {
        try await ContainerCLI.run(args, timeout: timeout)
    }
}

enum K8sError: Error, CustomStringConvertible {
    case createFailed(String)

    var description: String {
        switch self {
        case .createFailed(let msg): return "Cluster creation failed: \(msg)"
        }
    }
}

struct KubernetesView: View {
    @State private var vm = KubernetesVM()
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Cluster Configuration") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            Text("Status")
                                .foregroundStyle(.secondary)
                            // "Not created" already says stopped; showing both
                            // reads as two different states.
                            if vm.clusterStatus == .notCreated {
                                Text("Not created")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            } else {
                                HStack(spacing: 8) {
                                    StatusBadge(status: vm.clusterStatus.badgeKind)
                                    Text(vm.clusterStatus.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        GridRow {
                            Text("Name")
                                .foregroundStyle(.secondary)
                            TextField("Cluster name", text: $vm.clusterName)
                                .textFieldStyle(.roundedBorder)
                                .disabled(vm.clusterStatus != .notCreated)
                        }

                        GridRow {
                            Text("Node Image")
                                .foregroundStyle(.secondary)
                            TextField("docker.io/kindest/node:v1.34.0", text: $vm.nodeImage)
                                .textFieldStyle(.roundedBorder)
                                .disabled(vm.clusterStatus != .notCreated)
                        }
                        if !vm.nodeImage.isEmpty,
                           !(vm.nodeImage.contains("/") && vm.nodeImage.contains(":")) {
                            Text("That doesn't look like a full image reference (registry/name:tag).")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 4)

                    switch vm.clusterStatus {
                    case .running, .stopped, .error:
                        HStack {
                            Spacer()
                            Button("Delete Cluster…", role: .destructive) {
                                showDeleteConfirmation = true
                            }
                            .controlSize(.small)
                            .disabled(vm.isDeleting)
                        }
                    case .notCreated, .creating, .starting, .stopping:
                        EmptyView()
                    }
                }

                if vm.clusterStatus == .running, let kcPath = vm.kubeconfigPath {
                    GroupBox("Connection") {
                        VStack(alignment: .leading, spacing: 12) {
                            CopyableRow(label: "Kubeconfig", value: kcPath)
                            CopyableRow(label: "Connect", value: "export KUBECONFIG=\"\(kcPath)\"")
                            CopyableRow(label: "Get Nodes", value: "kubectl get nodes")
                            CopyableRow(label: "Get Pods", value: "kubectl get pods -A")
                        }
                        .padding(.top, 4)
                    }
                }

                GroupBox("Cluster Output") {
                    if vm.isCreating || !vm.output.isEmpty {
                        ScrollView {
                            Text(vm.output.isEmpty ? "Working…" : vm.output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(minHeight: 220, alignment: .top)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        EmptyState(
                            vm.clusterStatus == .stopped ? "Cluster Stopped" : "No Kubernetes Cluster",
                            description: vm.clusterStatus == .stopped
                                ? "Choose Start from the toolbar to resume the cluster."
                                : "Configure the cluster and choose Create Cluster from the toolbar.",
                            systemImage: "helm"
                        )
                    }
                }
            }
            .padding(20)
        }
        .errorBanner($vm.errorMessage)
        .alert("Delete Cluster \(vm.clusterName)?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await vm.deleteCluster() }
            }
        } message: {
            Text("This deletes the cluster container and its extracted kubeconfig. This action cannot be undone.")
        }
        .navigationTitle("Kubernetes")
        .toolbar {
            ToolbarItem(id: "help", placement: .automatic) {
                SectionHelpButton(section: .kubernetes)
            }

            ToolbarItem(id: "cluster-action", placement: .primaryAction) {
                HStack(spacing: 8) {
                    switch vm.clusterStatus {
                    case .notCreated:
                        Button {
                            Task { await vm.createCluster() }
                        } label: {
                            Label("Create Cluster", systemImage: "plus")
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderedProminent)
                        .help("Create a single-node Kubernetes cluster on this Mac")

                    case .running:
                        Button {
                            Task { await vm.stopCluster() }
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .labelStyle(.titleAndIcon)
                        .help("Stop the Kubernetes cluster (data is kept)")

                    case .stopped:
                        Button {
                            Task { await vm.startCluster() }
                        } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderedProminent)
                        .help("Start the Kubernetes cluster again")

                    case .creating, .starting, .stopping:
                        ProgressView().controlSize(.small)

                    case .error:
                        Button {
                            Task { await vm.checkClusterStatus() }
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .labelStyle(.titleAndIcon)
                        .help("Check the cluster status again")
                    }
                }
                .disabled(vm.clusterStatus.isBusy || vm.isDeleting)
            }
        }
        .toolbarRole(.editor)
        .task {
            await vm.checkClusterStatus()
        }
    }
}

