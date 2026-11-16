import AppKit
import SwiftUI

struct SettingsPage: View {
    @EnvironmentObject private var model: MixerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                languageCard
                stripsCard
            }
            .padding(12)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var languageCard: some View {
        SettingsCard(title: "Язык", subtitle: "Language / Sprache / Idioma / Langue / 语言") {
            HStack(spacing: 10) {
                Picker("", selection: $model.appLanguage) {
                    Text("Системный").tag("system")
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                    Text("Deutsch").tag("de")
                    Text("Español").tag("es")
                    Text("Français").tag("fr")
                    Text("中文").tag("zh-Hans")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
                Spacer()
            }
        }
    }

    private var stripsCard: some View {
        SettingsCard(title: "Полосы микшера",
                     subtitle: "Скройте неиспользуемые каналы и шины — окно можно сделать компактнее") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], spacing: 6) {
                ForEach(model.channels) { channel in
                    Toggle(isOn: Binding(
                        get: { !model.hiddenChannels.contains(channel.id) },
                        set: { model.setChannel(channel.id, hidden: !$0) }
                    )) {
                        Text(channel.name)
                            .font(.system(size: 10))
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
                ForEach(model.buses) { bus in
                    Toggle(isOn: Binding(
                        get: { !model.hiddenBuses.contains(bus.id) },
                        set: { model.setBus(bus.id, hidden: !$0) }
                    )) {
                        Text(bus.title)
                            .font(.system(size: 10))
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
            }

            HStack {
                Button("Показать все полосы") {
                    model.showAllStrips()
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
                .disabled(model.hiddenStripCount == 0)
                Spacer()
                if model.hiddenStripCount > 0 {
                    Text("Скрыто: \(model.hiddenStripCount)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }


}

private struct SettingsCard<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let content: Content

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stripCard(radius: 10)
    }
}

private struct SettingsRow: View {
    let title: LocalizedStringKey
    let value: LocalizedStringKey
    var valueColor: Color = .secondary
    let actionTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(valueColor)
                .lineLimit(1)
            Spacer()
            Button(actionTitle, action: action)
                .font(.system(size: 10))
                .buttonStyle(.borderless)
        }
    }
}
