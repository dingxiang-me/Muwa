//
//  OnboardingCreateAgentView.swift
//  osaurus
//
//  Onboarding step 2 — a stripped-down "Create your agent" form.
//  Split into:
//    - `CreateAgentState`: ObservableObject holding form state (lives in
//      OnboardingView via @StateObject, so values survive slide transitions).
//    - `CreateAgentBody`: the body slot (template strip + name + mascot).
//    - `CreateAgentCTA`: the primary "Create Agent" footer button.
//    - `CreateAgentSecondary`: the leading "Skip for now" text link.
//

import SwiftUI

// MARK: - State

@MainActor
final class CreateAgentState: ObservableObject {
    @Published var selectedTemplate: AgentStarterTemplate = .writer
    @Published var name: String = ""
    /// Flips to `true` once the user types into the name field, so switching
    /// presets stops clobbering their input.
    @Published var nameUserEdited: Bool = false
    @Published var selectedAvatar: String? = AgentMascot.allCases.first?.id
    @Published var isSaving: Bool = false

    init() {
        applyTemplate(.writer)
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSave: Bool { !trimmedName.isEmpty && !isSaving }

    func applyTemplate(_ template: AgentStarterTemplate) {
        selectedTemplate = template
        if !nameUserEdited {
            name = template.defaultName
        }
    }

    /// Persists the agent and returns whether save succeeded. The caller is
    /// responsible for advancing the flow afterwards.
    @discardableResult
    func saveAgent() -> Bool {
        guard !trimmedName.isEmpty, !isSaving else { return false }
        isSaving = true
        let agent = Agent(
            id: UUID(),
            name: trimmedName,
            description: "",
            systemPrompt: selectedTemplate.systemPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date(),
            updatedAt: Date(),
            toolSelectionMode: .auto,
            avatar: selectedAvatar
        )
        AgentManager.shared.add(agent)
        isSaving = false
        return true
    }
}

// MARK: - Body

struct CreateAgentBody: View {
    @ObservedObject var state: CreateAgentState

    @Environment(\.theme) private var theme

    var body: some View {
        OnboardingTwoColumnBody(
            illustrationAsset: "osaurus-onboarding-agent",
            leftHeadline: "Meet your assistant",
            leftBody:
                "Pick a starter, give it a name, and choose a mascot. Fine-tune the prompt, model, and tools later in the Agents tab.",
            subtitle: "A starting point — change anything later."
        ) {
            VStack(alignment: .leading, spacing: OnboardingMetrics.sectionSpacing) {
                templatesSection
                nameSection
                mascotSection
            }
        }
    }

    // MARK: - Templates

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.labelToInput) {
            sectionLabel("Start From")
            HStack(spacing: 6) {
                ForEach(AgentStarterTemplate.allCases) { template in
                    templateChip(template)
                }
            }
        }
    }

    private func templateChip(_ template: AgentStarterTemplate) -> some View {
        let isSelected = state.selectedTemplate == template
        return Button {
            withAnimation(theme.animationQuick()) {
                state.applyTemplate(template)
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: template.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(height: 16)
                Text(LocalizedStringKey(template.label), bundle: .module)
                    .font(theme.font(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? theme.accentColor.opacity(0.12) : theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                isSelected ? theme.accentColor.opacity(0.45) : theme.inputBorder,
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.labelToInput) {
            sectionLabel("Name")
            OnboardingTextField(
                label: "",
                placeholder: "e.g. Code Assistant",
                text: $state.name
            )
            .onChange(of: state.name) { _, newValue in
                if newValue != state.selectedTemplate.defaultName {
                    state.nameUserEdited = true
                }
            }
        }
    }

    // MARK: - Mascot

    private var mascotSection: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.labelToInput) {
            sectionLabel("Mascot")
            HStack(spacing: 10) {
                avatarChip(mascotId: nil)
                ForEach(AgentMascot.allCases) { mascot in
                    avatarChip(mascotId: mascot.id)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    private func avatarChip(mascotId: String?) -> some View {
        let isSelected = state.selectedAvatar == mascotId
        return Button {
            withAnimation(theme.animationQuick()) {
                state.selectedAvatar = mascotId
            }
        } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .fill(theme.accentColor.opacity(0.18))
                        .frame(width: 46, height: 46)
                        .blur(radius: 6)
                }

                AgentAvatarView(
                    mascotId: mascotId,
                    name: state.name,
                    tint: agentColorFor(state.name),
                    diameter: 34,
                    monogramFontSize: 13,
                    borderWidth: 1.5
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            isSelected ? theme.accentColor : Color.clear,
                            lineWidth: 2
                        )
                        .padding(-3)
                )
            }
            .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .help(Text(mascotId.map { "Mascot: \($0)" } ?? "Initial", bundle: .module))
    }

    @ViewBuilder
    private func sectionLabel(_ key: String) -> some View {
        Text(LocalizedStringKey(key), bundle: .module)
            .textCase(.uppercase)
            .font(theme.font(size: OnboardingMetrics.sectionLabelSize, weight: .bold))
            .tracking(0.6)
            .foregroundColor(theme.tertiaryText)
    }
}

// MARK: - CTA

struct CreateAgentCTA: View {
    @ObservedObject var state: CreateAgentState
    let onContinue: () -> Void

    var body: some View {
        OnboardingBrandButton(
            title: "Create Agent",
            action: { if state.saveAgent() { onContinue() } },
            isEnabled: state.canSave
        )
        .frame(width: OnboardingMetrics.ctaWidthCompact)
    }
}

// MARK: - Secondary

struct CreateAgentSecondary: View {
    let onSkip: () -> Void

    var body: some View {
        OnboardingTextButton(title: "Skip for now", action: onSkip)
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingCreateAgentView_Previews: PreviewProvider {
        static var previews: some View {
            let state = CreateAgentState()
            return VStack {
                CreateAgentBody(state: state).frame(height: 460)
                HStack {
                    CreateAgentSecondary(onSkip: {})
                    Spacer()
                    CreateAgentCTA(state: state, onContinue: {})
                }
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 620)
        }
    }
#endif
