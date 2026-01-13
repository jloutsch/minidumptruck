import SwiftUI
import MiniDumpTruckCore

struct SystemInfoView: View {
    let systemInfo: SystemInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Operating System
                GroupBox("Operating System") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        GridRow {
                            Text("Version:")
                                .fontWeight(.medium)
                            Text(systemInfo.windowsVersionName)
                        }

                        GridRow {
                            Text("Build:")
                                .fontWeight(.medium)
                            Text(systemInfo.osVersionString)
                        }

                        GridRow {
                            Text("Platform:")
                                .fontWeight(.medium)
                            Text(systemInfo.platformId.displayName)
                        }

                        GridRow {
                            Text("Product Type:")
                                .fontWeight(.medium)
                            Text(systemInfo.productType.displayName)
                        }

                        if let csd = systemInfo.csdVersion, !csd.isEmpty {
                            GridRow {
                                Text("Service Pack:")
                                    .fontWeight(.medium)
                                Text(csd)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Processor
                GroupBox("Processor") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        GridRow {
                            Text("Architecture:")
                                .fontWeight(.medium)
                            Text(systemInfo.processorArchitecture.displayName)
                        }

                        GridRow {
                            Text("Count:")
                                .fontWeight(.medium)
                            Text("\(systemInfo.numberOfProcessors)")
                        }

                        GridRow {
                            Text("Level:")
                                .fontWeight(.medium)
                            Text("\(systemInfo.processorLevel)")
                        }

                        GridRow {
                            Text("Revision:")
                                .fontWeight(.medium)
                            Text(String(format: "0x%04X", systemInfo.processorRevision))
                                .fontDesign(.monospaced)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // CPU Info
                GroupBox("CPU Details") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        GridRow {
                            Text("Vendor:")
                                .fontWeight(.medium)
                            Text(systemInfo.cpuInfo.vendorString)
                        }

                        GridRow {
                            Text("Family:")
                                .fontWeight(.medium)
                            Text("\(systemInfo.cpuInfo.displayFamily)")
                        }

                        GridRow {
                            Text("Model:")
                                .fontWeight(.medium)
                            Text("\(systemInfo.cpuInfo.displayModel)")
                        }

                        GridRow {
                            Text("Stepping:")
                                .fontWeight(.medium)
                            Text("\(systemInfo.cpuInfo.stepping)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle("System Information")
    }
}
