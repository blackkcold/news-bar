import SwiftUI

/// The documented OpenCode price list.
///
/// Static data only: this sheet never touches the network, needs no API key and
/// no workspace id. Every number comes from the generated catalog or from the
/// plan terms published at opencode.ai/docs/console/go.
struct OpenCodePricingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private let currentModel: String

    @State private var plan: OpenCodePricingPlan
    @State private var currency: OpenCodePriceCurrency = .usd
    @State private var query = ""
    @State private var hoveredModel: String?

    init(currentModel: String, initialPlan: OpenCodePricingPlan = .go) {
        self.currentModel = currentModel
        _plan = State(initialValue: initialPlan)
    }

    private var rows: [OpenCodePriceRow] {
        OpenCodePriceSheet.rows(plan: plan, query: query, currentModel: currentModel)
    }

    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            columnHeader
            Divider()
            table
            Divider()
            footer
        }
        .frame(width: 760, height: 560)
        .appThemeSurface()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("settings.pricing.title".localized)
                    .editorialHeading(size: 16)
                Text(L10n.string("settings.pricing.subtitle", OpenCodePriceCatalog.updatedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(countText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .editorialMasthead()
    }

    private var countText: String {
        if isFiltering {
            return L10n.string("settings.pricing.countFiltered", rows.count, OpenCodePriceSheet.listedCount(for: plan))
        }
        return L10n.string("settings.pricing.count", rows.count)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            EditorialChips(
                values: OpenCodePricingPlan.allCases,
                title: { L10n.string($0.titleKey) },
                groupLabel: "settings.pricing.plan".localized,
                selection: $plan
            )

            Spacer(minLength: 8)

            searchField

            EditorialChips(
                values: OpenCodePriceCurrency.allCases,
                title: { $0.symbol },
                groupLabel: "settings.pricing.currency".localized,
                selection: $currency
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("settings.pricing.search".localized, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .frame(width: 124)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("settings.pricing.search.clear".localized)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            let retro = settings.appTheme == .retroEditorial
            let shape = EditorialSurfaceShape(cornerRadius: 6, isRetro: retro)
            shape
                .fill(retro ? RetroEditorialTokens.paper : Color(nsColor: .textBackgroundColor))
                .overlay {
                    shape.strokeBorder(
                        retro ? RetroEditorialTokens.ink.opacity(0.45) : Color(nsColor: .separatorColor),
                        lineWidth: 1
                    )
                }
        }
    }

    // MARK: - Columns

    private enum Column {
        static let input: CGFloat = 88
        static let output: CGFloat = 88
        static let cache: CGFloat = 96
        static let allowance: CGFloat = 92
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("settings.pricing.col.model".localized)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("settings.pricing.col.input".localized)
                .frame(width: Column.input, alignment: .trailing)
            Text("settings.pricing.col.output".localized)
                .frame(width: Column.output, alignment: .trailing)
            Text("settings.pricing.col.cacheRead".localized)
                .frame(width: Column.cache, alignment: .trailing)
            Text(allowanceHeader)
                .frame(width: Column.allowance, alignment: .trailing)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .accessibilityHidden(true)
    }

    private var allowanceHeader: String {
        plan.isZen
            ? "settings.pricing.col.billing".localized
            : "settings.pricing.col.allowance".localized
    }

    // MARK: - Table

    private var table: some View {
        ScrollView {
            if rows.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowView(_ row: OpenCodePriceRow) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(row.model)
                    .font(.system(size: 11.5, weight: row.isCurrent ? .semibold : .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if row.isCurrent {
                    EditorialTag(
                        text: "settings.pricing.current".localized,
                        fallbackTint: .accentColor,
                        filled: settings.appTheme == .retroEditorial
                    )
                }

                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            numberCell(OpenCodePriceSheet.money(row.inputUSDPerMTok, currency: currency), width: Column.input)
            numberCell(OpenCodePriceSheet.money(row.outputUSDPerMTok, currency: currency), width: Column.output)
            numberCell(
                OpenCodePriceSheet.price(row.cacheReadUSDPerMTok, currency: currency),
                width: Column.cache,
                muted: row.cacheReadUSDPerMTok == nil
            )
            allowanceCell(row.allowance)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
        .background { rowBackground(row) }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.055))
                .frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredModel = row.model
            } else if hoveredModel == row.model {
                hoveredModel = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(row))
    }

    /// The current row is tinted with the theme's own accent: on paper the
    /// system accent reads as a blue-gray band that clashes with the page.
    @ViewBuilder
    private func rowBackground(_ row: OpenCodePriceRow) -> some View {
        if row.isCurrent {
            (settings.appTheme == .retroEditorial ? RetroEditorialTokens.brick : Color.accentColor)
                .opacity(settings.appTheme == .retroEditorial ? 0.16 : 0.10)
        } else if hoveredModel == row.model {
            Color.primary.opacity(0.04)
        } else {
            Color.clear
        }
    }

    private func numberCell(_ text: String, width: CGFloat, muted: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(muted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .frame(width: width, alignment: .trailing)
    }

    private func allowanceCell(_ allowance: OpenCodeAllowance) -> some View {
        Text(OpenCodePriceSheet.allowanceText(allowance, currency: currency))
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(allowanceTint(allowance))
            .frame(width: Column.allowance, alignment: .trailing)
    }

    private func allowanceTint(_ allowance: OpenCodeAllowance) -> AnyShapeStyle {
        switch allowance {
        case .monthlyUSD: return AnyShapeStyle(.primary)
        case .unlimited: return AnyShapeStyle(.green)
        case .metered: return AnyShapeStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("settings.pricing.empty".localized)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if isFiltering {
                Button("settings.pricing.search.clear".localized) {
                    query = ""
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private func accessibilityLabel(_ row: OpenCodePriceRow) -> String {
        L10n.string(
            "settings.pricing.row.accessibility",
            row.model,
            OpenCodePriceSheet.money(row.inputUSDPerMTok, currency: currency),
            OpenCodePriceSheet.money(row.outputUSDPerMTok, currency: currency),
            OpenCodePriceSheet.price(row.cacheReadUSDPerMTok, currency: currency),
            OpenCodePriceSheet.allowanceText(row.allowance, currency: currency)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("settings.pricing.note.source"))
                Text(plan.isZen ? "settings.pricing.note.zen".localized : "settings.pricing.note.go".localized)
                if !plan.isZen {
                    Text("settings.pricing.note.peak".localized)
                }
                Link("settings.pricing.console".localized, destination: URL(string: "https://opencode.ai/console")!)
                    .font(.system(size: 10, weight: .medium))
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Text("settings.pricing.done".localized)
            }
            .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
