import SwiftUI

/// Shared repair surface for an unregistered boot kernel (container 1.4+
/// runtimes refuse to start containers until one exists). Compact banner for
/// screens where the user is blocked right now (Run sheet, Health); full
/// status card for Settings → Apple Containers.
///
/// Both render nothing unless the runtime actually reported the kernel
/// missing — a legacy runtime or a failed probe never nags.

/// Compact orange banner: explains the state and offers the one-click fix.
struct BootKernelWarningBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if case .missing = appState.bootKernelStatus {
            VStack(alignment: .leading, spacing: 8) {
                Label("No boot kernel configured", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("The container runtime has no default kernel registered, so new containers fail with “default kernel not configured”. This usually follows a runtime upgrade.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                repairControls
                if let notice = appState.bootKernelNotice {
                    Text(notice.message)
                        .font(.caption)
                        .foregroundStyle(notice.isError ? Color.red : Color.green)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
        }
    }

    @ViewBuilder
    private var repairControls: some View {
        if appState.isInstallingBootKernel {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading the recommended kernel…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button("Install Recommended Kernel") {
                Task { await appState.installRecommendedBootKernel() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }
}

/// Full status card for Settings → Apple Containers: the registered kernel
/// (or missing/legacy state), the one-click repair, and a manual re-check.
struct BootKernelStatusCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if appState.isInstallingBootKernel {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    switch appState.bootKernelStatus {
                    case .missing:
                        Button("Install Recommended Kernel") {
                            Task { await appState.installRecommendedBootKernel() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    case .ok:
                        // Re-downloads the runtime's recommended kernel — the
                        // refresh path when a brew upgrade moves the runtime
                        // past the registered kernel.
                        Button("Reinstall") {
                            Task { await appState.installRecommendedBootKernel() }
                        }
                        .controlSize(.small)
                    case .unchecked, .legacyRuntime, .unknown:
                        EmptyView()
                    }
                    Button("Re-check") {
                        Task { await appState.checkBootKernel() }
                    }
                    .controlSize(.small)
                }
            }

            if appState.isInstallingBootKernel {
                Text("Downloading the runtime's recommended kernel — this can take a minute on a slow connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notice = appState.bootKernelNotice {
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(notice.isError ? Color.red : Color.green)
            }
        }
        .padding(.vertical, 4)
        .task {
            await appState.checkBootKernel()
        }
    }

    private var statusColor: Color {
        switch appState.bootKernelStatus {
        case .ok: return .green
        case .missing: return .orange
        case .unchecked, .legacyRuntime, .unknown: return .gray
        }
    }

    private var statusTitle: String {
        switch appState.bootKernelStatus {
        case .unchecked: return "Boot Kernel"
        case .ok: return "Boot Kernel Registered"
        case .missing: return "Boot Kernel Missing"
        case .legacyRuntime: return "Boot Kernel (automatic)"
        case .unknown: return "Boot Kernel"
        }
    }

    private var statusDetail: String {
        switch appState.bootKernelStatus {
        case .unchecked:
            return "Checking…"
        case .ok(let binaryPath):
            return "Registered: \(binaryPath)"
        case .missing:
            return "New containers can't start until a default kernel is registered — typical after a runtime upgrade."
        case .legacyRuntime:
            return "This runtime downloads a kernel on first use — nothing to manage."
        case .unknown:
            return "Couldn't check. Is the runtime running?"
        }
    }
}
