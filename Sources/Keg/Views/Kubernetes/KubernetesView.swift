import SwiftUI

@Observable
@MainActor
final class KubernetesVM {
    var clusterName = "keg-k8s"
    var clusterStatus: String = "Not Created"
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
        clusterStatus = "Creating..."

        do {
            // Start the container with kindest/node
            output += "Starting K8s node container...\n"
            let (code, out) = try await runCLI([
                "container", "run", "-d",
                "--name", clusterName,
                "-m", "8G",
                "-c", "4",
                "-e", "KUBECONFIG=/etc/kubernetes/admin.conf",
                "-p", "127.0.0.1:6443:6443",
                nodeImage
            ])
            if code != 0 {
                throw K8sError.createFailed(out)
            }
            output += out + "\n"

            // Wait for container to boot
            output += "Waiting for container to boot...\n"
            try await Task.sleep(for: .seconds(5))

            // Enable IP forwarding
            output += "Enabling IP forwarding...\n"
            let _ = try await runCLI(["container", "exec", clusterName, "sysctl", "-w", "net.ipv4.ip_forward=1"])

            // Initialize cluster with kubeadm
            output += "Initializing Kubernetes (this takes ~60s)...\n"
            let (initCode, initOut) = try await runCLI([
                "container", "exec", clusterName,
                "kubeadm", "init", "--pod-network-cidr=10.244.0.0/16"
            ])
            output += initOut + "\n"
            if initCode != 0 {
                throw K8sError.createFailed(initOut)
            }

            // Install CNI (kindnet)
            output += "Installing CNI...\n"
            let (_, cniOut) = try await runCLI([
                "container", "exec", clusterName, "sh", "-euc",
                "sed -e 's@{{ .PodSubnet }}@10.244.0.0/16@' /kind/manifests/default-cni.yaml | kubectl apply -f -"
            ])
            output += cniOut + "\n"

            // Remove taint for single-node
            output += "Removing control-plane taint...\n"
            let _ = try await runCLI([
                "container", "exec", clusterName,
                "kubectl", "taint", "nodes", "--all", "node-role.kubernetes.io/control-plane-"
            ])

            // Extract kubeconfig
            output += "Extracting kubeconfig...\n"
            let kubeconfigDir = NSHomeDirectory() + "/.keg"
            try FileManager.default.createDirectory(atPath: kubeconfigDir, withIntermediateDirectories: true)
            let kcPath = kubeconfigDir + "/kubeconfig"
            let (kcCode, kcOut) = try await runCLI([
                "container", "exec", clusterName, "cat", "/etc/kubernetes/admin.conf"
            ])
            if kcCode == 0 {
                try kcOut.write(toFile: kcPath, atomically: true, encoding: .utf8)
                kubeconfigPath = kcPath
                // Update server address to localhost
                if var kcContent = try? String(contentsOfFile: kcPath, encoding: .utf8) {
                    kcContent = kcContent.replacingOccurrences(of: "kubernetes.default.svc", with: "127.0.0.1")
                    kcContent = kcContent.replacingOccurrences(of: ":6443", with: ":6443")
                    try? kcContent.write(toFile: kcPath, atomically: true, encoding: .utf8)
                }
            }

            clusterStatus = "Running"
            output += "\n✅ Cluster ready!\n"
            output += "export KUBECONFIG=\"\(kcPath)\"\n"
            output += "kubectl get nodes\n"
        } catch {
            errorMessage = error.localizedDescription
            clusterStatus = "Error"
        }
        isCreating = false
    }

    func deleteCluster() async {
        isDeleting = true
        output = ""
        errorMessage = nil

        let result = try? await runCLI(["container", "delete", "-f", clusterName])
        if let (code, _) = result, code == 0 || code == 1 {
            // Remove kubeconfig
            if let kcPath = kubeconfigPath {
                try? FileManager.default.removeItem(atPath: kcPath)
            }
            kubeconfigPath = nil
            clusterStatus = "Not Created"
            output = "Cluster deleted"
        } else {
            errorMessage = result?.1 ?? "Delete failed"
        }
        isDeleting = false
    }

    func checkClusterStatus() async {
        let (code, _) = (try? await runCLI(["container", "list", "--format", "json"])) ?? (1, "")
        if code == 0 {
            // Check if our cluster container is running
            let (inspectCode, _) = (try? await runCLI(["container", "inspect", clusterName])) ?? (1, "")
            if inspectCode == 0 {
                clusterStatus = "Running"
                kubeconfigPath = NSHomeDirectory() + "/.keg/kubeconfig"
            } else {
                clusterStatus = "Not Created"
            }
        }
    }

    private func runCLI(_ args: [String]) async throws -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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

    var body: some View {
        Group {
            if vm.isCreating {
                VStack(spacing: 16) {
                    ProgressView("Creating Kubernetes cluster (~60s)...")
                    if !vm.output.isEmpty {
                        ScrollView {
                            Text(vm.output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                        .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.clusterStatus == "Running" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Output log
                        if !vm.output.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Cluster Output")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(vm.output)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }

                        // Connection info
                        if let kcPath = vm.kubeconfigPath {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Connection")
                                    .font(.headline)

                                CopyableRow(label: "Kubeconfig", value: kcPath)

                                CopyableRow(
                                    label: "Connect",
                                    value: "export KUBECONFIG=\"\(kcPath)\""
                                )

                                CopyableRow(
                                    label: "Get Nodes",
                                    value: "kubectl get nodes"
                                )

                                CopyableRow(
                                    label: "Get Pods",
                                    value: "kubectl get pods -A"
                                )
                            }
                        }
                    }
                    .padding(16)
                }
            } else if vm.clusterStatus == "Not Created" && vm.output.isEmpty {
                ContentUnavailableView(
                    "No Kubernetes Cluster",
                    systemImage: "helm",
                    description: Text("Create a single-node Kubernetes cluster using Apple Containers")
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let error = vm.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Dismiss") { vm.errorMessage = nil }
                        .controlSize(.small)
                    Spacer()
                }
                .padding(8)
                .background(.bar, in: RoundedRectangle(cornerRadius: 6))
                .padding(12)
            }
        }
        .navigationTitle("Kubernetes")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    TextField("Cluster", text: $vm.clusterName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 140)
                        .disabled(vm.isCreating || vm.clusterStatus == "Running")

                    TextField("Node image", text: $vm.nodeImage)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 280)
                        .disabled(vm.isCreating || vm.clusterStatus == "Running")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    StatusBadge(status: vm.clusterStatus == "Running" ? "running" : vm.clusterStatus == "Creating..." ? "created" : "stopped")

                    if vm.clusterStatus == "Running" {
                        Button("Delete Cluster", role: .destructive) {
                            Task { await vm.deleteCluster() }
                        }
                    } else if vm.clusterStatus == "Not Created" {
                        Button("Create Cluster") {
                            Task { await vm.createCluster() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isCreating)
                    }
                }
            }
        }
        .task {
            await vm.checkClusterStatus()
        }
    }
}

struct CopyableRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }
}
