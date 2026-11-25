import Charts
import SwiftUI

struct MacDistributionCard: View {
    let title: String
    let counts: [Int: Int]
    let labels: [String]
    let colors: [Color]
    let symbol: String

    private var total: Int { counts.values.reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
                Text(total == 0 ? "暂无记录" : "\(total) 次记录").font(.caption).foregroundStyle(.secondary)
            }
            if total == 0 {
                Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 135)
            } else {
                HStack(spacing: 18) {
                    Chart(1...5, id: \.self) { score in
                        if let count = counts[score], count > 0 {
                            SectorMark(angle: .value("次数", count), innerRadius: .ratio(0.74), angularInset: 3)
                                .foregroundStyle(colors[score - 1]).cornerRadius(3)
                                .accessibilityLabel("\(labels[score - 1])，\(count) 次")
                        }
                    }
                    .chartBackground { _ in Text("\(total)").font(.title2.weight(.semibold)).monospacedDigit() }
                    .frame(width: 112, height: 112)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(1...5, id: \.self) { score in
                            HStack(spacing: 6) {
                                Circle().fill(colors[score - 1]).frame(width: 6, height: 6)
                                Text(labels[score - 1]).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text("\(counts[score] ?? 0)").monospacedDigit()
                            }.font(.caption)
                        }
                    }
                }.frame(minHeight: 135)
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }
}
