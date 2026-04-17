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
            if code != 0 { throw K8sError.createFailed(out) }
            output += out + "\n"

            output += "Waiting for container to boot...\n"
            try await Task.sleep(for: .seconds(5))

            output += "Enabling IP forwarding...\n"
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

        do {
            let (code, out) = try await runCLI(["container", "delete", "-f", clusterName])
            if code == 0 {
                if let kcPath = kubeconfigPath { try? FileManager.default.removeItem(atPath: kcPath) }
                kubeconfigPath = nil
                clusterStatus = "Not Created"
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
            let (code, _) = try await runCLI(["container", "list", "--format", "json"])
            guard code == 0 else { return }
            let (inspectCode, _) = try await runCLI(["container", "inspect", clusterName])
            guard inspectCode == 0 else {
                clusterStatus = "Not Created"
                return
            }
            clusterStatus = "Running"
            let kcPath = NSHomeDirectory() + "/.keg/kubeconfig"
            if !FileManager.default.fileExists(atPath: kcPath) {
                // Cluster survived but kubeconfig was lost — re-extract so `kubectl` works.
                let (kcCode, kcOut) = try await runCLI([
                    "container", "exec", clusterName, "cat", "/etc/kubernetes/admin.conf"
                ])
                if kcCode == 0 {
                    let dir = (kcPath as NSString).deletingLastPathComponent
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    let content = kcOut.replacingOccurrences(of: "kubernetes.default.svc", with: "127.0.0.1")
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Cluster Configuration") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            Text("Status")
                                .foregroundStyle(.secondary)
                            StatusBadge(status: vm.clusterStatus == "Running" ? "running" : vm.clusterStatus == "Creating..." ? "created" : "stopped")
                        }

                        GridRow {
                            Text("Name")
                                .foregroundStyle(.secondary)
                            TextField("Cluster name", text: $vm.clusterName)
                                .textFieldStyle(.roundedBorder)
                                .disabled(vm.isCreating || vm.clusterStatus == "Running")
                        }

                        GridRow {
                            Text("Node Image")
                                .foregroundStyle(.secondary)
                            TextField("docker.io/kindest/node:v1.34.0", text: $vm.nodeImage)
                                .textFieldStyle(.roundedBorder)
                                .disabled(vm.isCreating || vm.clusterStatus == "Running")
                        }
                    }
                    .padding(.top, 4)
                }

                if vm.clusterStatus == "Running", let kcPath = vm.kubeconfigPath {
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
                        ContentUnavailableView(
                            "No Kubernetes Cluster",
                            systemImage: "helm",
                            description: Text("Configure the cluster and choose Create Cluster from the toolbar.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
            }
            .padding(20)
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
        .toolbar(id: "kubernetes-toolbar") {
            ToolbarItem(id: "cluster-action", placement: .primaryAction) {
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
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .toolbarRole(.editor)
        .task {
            await vm.checkClusterStatus()
        }
    }
}

struct CopyableRow: View {
    @State private var isHovered = false

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
                    copyValue()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Copy \(label)")
            }
        }
        .padding(8)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .onTapGesture { copyValue() }
        .help("Click to copy \(label.lowercased())")
    }

    private func copyValue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
