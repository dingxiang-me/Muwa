import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

@Suite(.serialized)
struct EvalBootstrapPlanTests {
    @Test func pluginRequiredCapabilitySearchSkipsBootstrapByDefault() {
        let suite = makeSuite(
            cases: [
                makeCase(
                    id: "capability_search.browser-prefix",
                    domain: "capability_search",
                    requirePlugins: ["osaurus.browser"]
                )
            ]
        )

        let plan = EvalBootstrapPlan.make(
            suite: suite,
            filter: "browser-prefix",
            preference: .automatic
        )

        #expect(plan == EvalBootstrapPlan(loadInstalledPlugins: false, initializeSearchIndices: false))
    }

    @Test func capabilitySearchInitializesIndicesWithoutPluginLoadingByDefault() {
        let suite = makeSuite(
            cases: [
                makeCase(
                    id: "capability_search.workflow-paraphrase",
                    domain: "capability_search",
                    expectedWorkflows: true
                )
            ]
        )

        let plan = EvalBootstrapPlan.make(
            suite: suite,
            filter: "workflow-paraphrase",
            preference: .automatic
        )

        #expect(
            plan
                == EvalBootstrapPlan(
                    loadInstalledPlugins: false,
                    searchIndexScope: EvalSearchIndexBootstrapScope(workflows: true)
                )
        )
        #expect(plan.usesIsolatedSearchStorage)
    }

    @Test func capabilitySearchScopesIndexBootstrapToSelectedLanes() {
        let suite = makeSuite(
            cases: [
                makeCase(
                    id: "capability_search.skill-direct-name",
                    domain: "capability_search",
                    expectedSkills: true,
                    enableSkills: ["Research Analyst"]
                )
            ]
        )

        let plan = EvalBootstrapPlan.make(
            suite: suite,
            filter: "skill-direct-name",
            preference: .automatic
        )

        #expect(
            plan
                == EvalBootstrapPlan(
                    loadInstalledPlugins: false,
                    searchIndexScope: EvalSearchIndexBootstrapScope(skills: true)
                )
        )
    }

    @Test func agentLoopWorkflowCasesClaimWorkflowsScope() {
        // Each workflow-touching fixture shape independently brings up the
        // workflows lane: seeded workflows, a workflows-enabled agent, and
        // a `workflowSaved` outcome assertion.
        let shapes: [EvalCase] = [
            makeCase(
                id: "workflows.run-with-params",
                domain: "agent_loop",
                seedWorkflows: [
                    EvalCase.SeedWorkflow(
                        id: "eval-write-greeting",
                        name: "write_greeting",
                        description: "Writes a greeting file."
                    )
                ]
            ),
            makeCase(
                id: "workflows.enable-only",
                domain: "agent_loop",
                enableWorkflows: true
            ),
            makeCase(
                id: "workflows.save-after-task",
                domain: "agent_loop",
                workflowSaved: EvalCase.AgentLoopExpectations.WorkflowSavedAssertion(minSteps: 1)
            ),
        ]

        for shape in shapes {
            let plan = EvalBootstrapPlan.make(
                suite: makeSuite(cases: [shape]),
                filter: nil,
                preference: .automatic
            )
            #expect(
                plan
                    == EvalBootstrapPlan(
                        loadInstalledPlugins: false,
                        searchIndexScope: EvalSearchIndexBootstrapScope(workflows: true)
                    ),
                "case \(shape.id) should claim the workflows scope"
            )
            #expect(plan.usesIsolatedSearchStorage)
        }
    }

    @Test func agentLoopCasesWithoutWorkflowFixturesSkipIndexBootstrap() {
        let suite = makeSuite(
            cases: [
                makeCase(id: "agent_loop.write-new-file", domain: "agent_loop")
            ]
        )

        let plan = EvalBootstrapPlan.make(suite: suite, filter: nil, preference: .automatic)

        #expect(plan == EvalBootstrapPlan(loadInstalledPlugins: false, initializeSearchIndices: false))
        #expect(!plan.requiresWork)
    }

    @Test func pureDataSuitesSkipStartupBootstrap() {
        let suite = makeSuite(cases: [makeCase(id: "schema.minimum-bound", domain: "schema")])

        let plan = EvalBootstrapPlan.make(suite: suite, filter: nil, preference: .automatic)

        #expect(plan == EvalBootstrapPlan(loadInstalledPlugins: false, initializeSearchIndices: false))
        #expect(!plan.requiresWork)
    }

    @Test func filterControlsAutomaticBootstrapPlan() {
        let suite = makeSuite(
            cases: [
                makeCase(
                    id: "capability_search.browser-prefix",
                    domain: "capability_search",
                    requirePlugins: ["osaurus.browser"]
                ),
                makeCase(id: "schema.minimum-bound", domain: "schema"),
            ]
        )

        let plan = EvalBootstrapPlan.make(
            suite: suite,
            filter: "minimum-bound",
            preference: .automatic
        )

        #expect(plan == EvalBootstrapPlan(loadInstalledPlugins: false, initializeSearchIndices: false))
    }

    @Test func explicitPluginPreferencesOverrideDomainDefault() {
        let suite = makeSuite(cases: [makeCase(id: "capability_search.browser-prefix", domain: "capability_search")])

        let forced = EvalBootstrapPlan.make(suite: suite, filter: nil, preference: .force)
        let disabled = EvalBootstrapPlan.make(
            suite: makeSuite(
                cases: [
                    makeCase(
                        id: "capability_search.workflow-paraphrase",
                        domain: "capability_search",
                        expectedWorkflows: true
                    )
                ]
            ),
            filter: nil,
            preference: .disabled
        )

        #expect(forced == EvalBootstrapPlan(loadInstalledPlugins: true, initializeSearchIndices: false))
        #expect(
            disabled
                == EvalBootstrapPlan(
                    loadInstalledPlugins: false,
                    searchIndexScope: EvalSearchIndexBootstrapScope(workflows: true)
                )
        )
    }

    @MainActor
    @Test func isolatedSearchStorageOverridesOsaurusRoot() {
        let previousRoot = OsaurusPaths.overrideRoot
        var isolatedRoot: URL?
        defer {
            OsaurusPaths.overrideRoot = previousRoot
            StorageKeyManager.shared.wipeCache()
            if let isolatedRoot {
                try? FileManager.default.removeItem(at: isolatedRoot)
            }
        }

        let root = EvalBootstrap.configureIsolatedSearchStorageIfNeeded(
            for: EvalBootstrapPlan(
                loadInstalledPlugins: false,
                searchIndexScope: EvalSearchIndexBootstrapScope(workflows: true)
            )
        )
        isolatedRoot = root

        #expect(root != nil)
        #expect(OsaurusPaths.overrideRoot == root)
        #expect(root?.lastPathComponent.hasPrefix("osaurus-evals-") == true)

        if let root {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }

    @MainActor
    @Test func nonIsolatedBootstrapDoesNotReplaceExistingRootOverride() {
        let previousRoot = OsaurusPaths.overrideRoot
        let existingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-evals-existing-\(UUID().uuidString)", isDirectory: true)
        OsaurusPaths.overrideRoot = existingRoot
        defer {
            OsaurusPaths.overrideRoot = previousRoot
        }

        let root = EvalBootstrap.configureIsolatedSearchStorageIfNeeded(
            for: EvalBootstrapPlan(loadInstalledPlugins: true, initializeSearchIndices: false)
        )

        #expect(root == nil)
        #expect(OsaurusPaths.overrideRoot == existingRoot)
    }

    private func makeSuite(cases: [EvalCase]) -> EvalSuite {
        EvalSuite(
            directory: URL(fileURLWithPath: "/tmp/Evals", isDirectory: true),
            cases: cases,
            decodeFailures: []
        )
    }

    private func makeCase(
        id: String,
        domain: String,
        requirePlugins: [String]? = nil,
        expectedTools: Bool = false,
        expectedWorkflows: Bool = false,
        expectedSkills: Bool = false,
        seedWorkflows: [EvalCase.SeedWorkflow]? = nil,
        enableWorkflows: Bool? = nil,
        enableSkills: [String]? = nil,
        workflowSaved: EvalCase.AgentLoopExpectations.WorkflowSavedAssertion? = nil
    ) -> EvalCase {
        let anyOf = EvalCase.CapabilitySearchExpectations.AnyOfMatcher(
            anyOf: [],
            minMatches: 0
        )
        let capabilitySearch =
            expectedTools || expectedWorkflows || expectedSkills
            ? EvalCase.CapabilitySearchExpectations(
                expectedTools: expectedTools ? anyOf : nil,
                expectedWorkflows: expectedWorkflows ? anyOf : nil,
                expectedSkills: expectedSkills ? anyOf : nil
            )
            : nil
        let agentLoop =
            workflowSaved != nil
            ? EvalCase.AgentLoopExpectations(workflowSaved: workflowSaved)
            : nil

        return EvalCase(
            id: id,
            domain: domain,
            query: "query",
            fixtures: .init(
                requirePlugins: requirePlugins,
                seedWorkflows: seedWorkflows,
                enableWorkflows: enableWorkflows,
                enableSkills: enableSkills
            ),
            expect: .init(capabilitySearch: capabilitySearch, agentLoop: agentLoop)
        )
    }
}
