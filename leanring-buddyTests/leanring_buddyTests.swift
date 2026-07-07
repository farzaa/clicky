import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    // MARK: - Permission Request Tests (Existing)

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    // MARK: - StepByStepGuideParser Tests

    @Test func parseValidGuideReturnsCorrectSteps() async throws {
        let response = """
        let me walk you through it
        [GUIDE:3]
        go to the file menu [POINT:50,10:file menu]
        ###
        click new project [POINT:200,150:new project]
        ###
        choose ios app [POINT:400,300:ios template]
        [END_GUIDE]
        """

        let result = StepByStepGuideParser.parse(from: response)

        #expect(result != nil)
        #expect(result?.guide.totalSteps == 3)
        #expect(result?.guide.steps.count == 3)
        #expect(result?.spokenText == "let me walk you through it")
    }

    @Test func parseValidGuideFirstStepHasCorrectData() async throws {
        let response = """
        [GUIDE:2]
        click the insert tab [POINT:500,30:insert tab]
        ###
        choose chart type [POINT:700,200:chart type:screen2]
        [END_GUIDE]
        """

        let result = StepByStepGuideParser.parse(from: response)

        #expect(result != nil)
        let firstStep = result?.guide.steps[0]
        #expect(firstStep?.index == 0)
        #expect(firstStep?.total == 2)
        #expect(firstStep?.instruction == "click the insert tab")
        #expect(firstStep?.rawPointCoordinate != nil)
        #expect(firstStep?.rawPointCoordinate?.x == 500)
        #expect(firstStep?.rawPointCoordinate?.y == 30)
        #expect(firstStep?.elementLabel == "insert tab")
        #expect(firstStep?.screenNumber == nil)
    }

    @Test func parseValidGuideSecondStepHasScreenNumber() async throws {
        let response = """
        [GUIDE:2]
        click the insert tab [POINT:500,30:insert tab]
        ###
        choose chart type [POINT:700,200:chart type:screen2]
        [END_GUIDE]
        """

        let result = StepByStepGuideParser.parse(from: response)

        let secondStep = result?.guide.steps[1]
        #expect(secondStep?.instruction == "choose chart type")
        #expect(secondStep?.rawPointCoordinate?.x == 700)
        #expect(secondStep?.rawPointCoordinate?.y == 200)
        #expect(secondStep?.elementLabel == "chart type")
        #expect(secondStep?.screenNumber == 2)
    }

    @Test func parseGuideWithNoPointTag() async throws {
        let response = """
        [GUIDE:2]
        just think about what you want to create
        ###
        then open the app [POINT:100,100:app icon]
        [END_GUIDE]
        """

        let result = StepByStepGuideParser.parse(from: response)

        #expect(result != nil)
        #expect(result?.guide.steps.count == 2)

        let firstStep = result?.guide.steps[0]
        #expect(firstStep?.instruction == "just think about what you want to create")
        #expect(firstStep?.rawPointCoordinate == nil)

        let secondStep = result?.guide.steps[1]
        #expect(secondStep?.instruction == "then open the app")
        #expect(secondStep?.rawPointCoordinate != nil)
    }

    @Test func parseGuideWithNonePoint() async throws {
        let response = """
        [GUIDE:1]
        go to settings [POINT:none]
        [END_GUIDE]
        """

        let result = StepByStepGuideParser.parse(from: response)

        #expect(result != nil)
        #expect(result?.guide.steps.count == 1)

        let step = result?.guide.steps[0]
        #expect(step?.instruction == "go to settings")
        #expect(step?.rawPointCoordinate == nil)
        #expect(step?.elementLabel == "none")
    }

    @Test func parseResponseWithoutGuideReturnsNil() async throws {
        let response = "you should click the file menu up top [POINT:50,10:file menu]"

        let result = StepByStepGuideParser.parse(from: response)

        #expect(result == nil)
    }

    @Test func parseGuideWithExtraNewlinesAndSpaces() async throws {
        let response = """
        okay!

        [GUIDE:2]

        step one here [POINT:100,100:step one]

        ###

        step two there [POINT:200,200:step two]

        [END_GUIDE]
        """

        let result = StepByStepGuideParser.parse(from: response)

        #expect(result != nil)
        #expect(result?.guide.steps.count == 2)
        #expect(result?.spokenText == "okay!")
    }

    @Test func parseGuideWithNoPreamble() async throws {
        let response = """
        [GUIDE:1]
        do the thing [POINT:300,300:the thing]
        [END_GUIDE]
        """

        let result = StepByStepGuideParser.parse(from: response)

        #expect(result != nil)
        #expect(result?.guide.steps.count == 1)
        #expect(result?.spokenText == "")
    }

    @Test func parseGuideWithMoreStepsThanDeclaredTruncates() async throws {
        let response = """
        [GUIDE:2]
        step one [POINT:100,100:one]
        ###
        step two [POINT:200,200:two]
        ###
        step three [POINT:300,300:three]
        [END_GUIDE]
        """

        let result = StepByStepGuideParser.parse(from: response)

        #expect(result != nil)
        #expect(result?.guide.steps.count == 2)
        #expect(result?.guide.totalSteps == 2)
    }

    @Test func parseEmptyGuideBodyReturnsNil() async throws {
        let response = """
        [GUIDE:0]
        [END_GUIDE]
        """

        let result = StepByStepGuideParser.parse(from: response)

        #expect(result == nil)
    }

    @Test func parseMalformedGuideMissingTotalReturnsNil() async throws {
        let response = """
        [GUIDE:]
        some step [POINT:100,100:test]
        [END_GUIDE]
        """

        let result = StepByStepGuideParser.parse(from: response)

        #expect(result == nil)
    }

    @Test func parseGuideWithPointCoordinatesAcrossMultipleDigits() async throws {
        let response = """
        [GUIDE:1]
        find the button [POINT:1234,567:big button]
        [END_GUIDE]
        """

        let result = StepByStepGuideParser.parse(from: response)

        #expect(result != nil)
        let step = result?.guide.steps[0]
        #expect(step?.rawPointCoordinate?.x == 1234)
        #expect(step?.rawPointCoordinate?.y == 567)
        #expect(step?.elementLabel == "big button")
    }

    // MARK: - StepAdvanceCommand Tests

    @Test func advanceCommandMatchesBasicNext() {
        #expect(StepAdvanceCommand.matches("next") == true)
    }

    @Test func advanceCommandMatchesWithWhitespace() {
        #expect(StepAdvanceCommand.matches("  next  ") == true)
    }

    @Test func advanceCommandMatchesCaseInsensitive() {
        #expect(StepAdvanceCommand.matches("NEXT") == true)
        #expect(StepAdvanceCommand.matches("Next") == true)
    }

    @Test func advanceCommandMatchesAllVariants() {
        #expect(StepAdvanceCommand.matches("next") == true)
        #expect(StepAdvanceCommand.matches("go on") == true)
        #expect(StepAdvanceCommand.matches("ok") == true)
        #expect(StepAdvanceCommand.matches("okay") == true)
        #expect(StepAdvanceCommand.matches("done") == true)
        #expect(StepAdvanceCommand.matches("continue") == true)
        #expect(StepAdvanceCommand.matches("ready") == true)
        #expect(StepAdvanceCommand.matches("got it") == true)
    }

    @Test func advanceCommandDoesNotMatchRandomPhrase() {
        #expect(StepAdvanceCommand.matches("what's next") == false)
        #expect(StepAdvanceCommand.matches("next step") == false)
        #expect(StepAdvanceCommand.matches("show me how") == false)
        #expect(StepAdvanceCommand.matches("") == false)
        #expect(StepAdvanceCommand.matches("   ") == false)
    }

    @Test func advanceCommandDoesNotMatchPartialWords() {
        #expect(StepAdvanceCommand.matches("nexting") == false)
        #expect(StepAdvanceCommand.matches("doned") == false)
        #expect(StepAdvanceCommand.matches("continues") == false)
    }

    // MARK: - GuidanceStep Model Tests

    @Test func guidanceStepInitializesCorrectly() {
        let step = GuidanceStep(
            index: 0,
            total: 3,
            instruction: "click the button",
            rawPointCoordinate: CGPoint(x: 100, y: 200),
            elementLabel: "button",
            screenNumber: 1
        )

        #expect(step.index == 0)
        #expect(step.total == 3)
        #expect(step.instruction == "click the button")
        #expect(step.rawPointCoordinate?.x == 100)
        #expect(step.rawPointCoordinate?.y == 200)
        #expect(step.elementLabel == "button")
        #expect(step.screenNumber == 1)
    }

    @Test func guidanceStepWithoutOptionalFields() {
        let step = GuidanceStep(
            index: 2,
            total: 5,
            instruction: "just think about it",
            rawPointCoordinate: nil,
            elementLabel: nil,
            screenNumber: nil
        )

        #expect(step.index == 2)
        #expect(step.total == 5)
        #expect(step.rawPointCoordinate == nil)
        #expect(step.elementLabel == nil)
        #expect(step.screenNumber == nil)
    }

    // MARK: - StepByStepGuide Model Tests

    @Test func guideCurrentStepReturnsCorrectStep() {
        let steps = [
            GuidanceStep(index: 0, total: 2, instruction: "first", rawPointCoordinate: nil, elementLabel: nil, screenNumber: nil),
            GuidanceStep(index: 1, total: 2, instruction: "second", rawPointCoordinate: nil, elementLabel: nil, screenNumber: nil)
        ]
        var guide = StepByStepGuide(totalSteps: 2, steps: steps)

        #expect(guide.currentStep?.instruction == "first")

        guide.currentStepIndex = 1
        #expect(guide.currentStep?.instruction == "second")
    }

    @Test func guideIsCompleteWhenPastLastStep() {
        let steps = [
            GuidanceStep(index: 0, total: 1, instruction: "only step", rawPointCoordinate: nil, elementLabel: nil, screenNumber: nil)
        ]
        var guide = StepByStepGuide(totalSteps: 1, steps: steps)

        #expect(guide.isComplete == false)

        guide.currentStepIndex = 1
        #expect(guide.isComplete == true)
    }

    @Test func guideProgressStartsAtZero() {
        let steps = [
            GuidanceStep(index: 0, total: 3, instruction: "a", rawPointCoordinate: nil, elementLabel: nil, screenNumber: nil),
            GuidanceStep(index: 1, total: 3, instruction: "b", rawPointCoordinate: nil, elementLabel: nil, screenNumber: nil),
            GuidanceStep(index: 2, total: 3, instruction: "c", rawPointCoordinate: nil, elementLabel: nil, screenNumber: nil)
        ]
        let guide = StepByStepGuide(totalSteps: 3, steps: steps)

        #expect(guide.progress == 0.0)
    }

    @Test func guideCurrentStepIsNilForEmptySteps() {
        let guide = StepByStepGuide(totalSteps: 0, steps: [])

        #expect(guide.currentStep == nil)
        #expect(guide.isComplete == false)
    }

    @Test func guideProgressPreventsDivisionByZero() {
        let guide = StepByStepGuide(totalSteps: 0, steps: [])

        #expect(guide.progress == 1.0)
    }

    // MARK: - CompanionManager Point Tag Parsing Tests

    @Test func parsePointingCoordinatesBasicPoint() {
        let response = "click the button up top [POINT:500,30:the button]"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.spokenText == "click the button up top")
        #expect(result.coordinate?.x == 500)
        #expect(result.coordinate?.y == 30)
        #expect(result.elementLabel == "the button")
        #expect(result.screenNumber == nil)
    }

    @Test func parsePointingCoordinatesNoneTag() {
        let response = "that's a general question [POINT:none]"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.spokenText == "that's a general question")
        #expect(result.coordinate == nil)
        #expect(result.elementLabel == "none")
    }

    @Test func parsePointingCoordinatesWithScreenNumber() {
        let response = "over on your other screen [POINT:400,300:terminal:screen2]"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.spokenText == "over on your other screen")
        #expect(result.coordinate?.x == 400)
        #expect(result.coordinate?.y == 300)
        #expect(result.elementLabel == "terminal")
        #expect(result.screenNumber == 2)
    }

    @Test func parsePointingCoordinatesNoTagReturnsFullText() {
        let response = "just a regular response with no point tag"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.spokenText == response)
        #expect(result.coordinate == nil)
        #expect(result.elementLabel == nil)
        #expect(result.screenNumber == nil)
    }

    @Test func parsePointingCoordinatesEmptyString() {
        let result = CompanionManager.parsePointingCoordinates(from: "")

        #expect(result.spokenText == "")
        #expect(result.coordinate == nil)
        #expect(result.elementLabel == nil)
    }

    @Test func stepByStepGuideEquality() {
        let step1 = GuidanceStep(index: 0, total: 1, instruction: "do it", rawPointCoordinate: CGPoint(x: 10, y: 20), elementLabel: "test", screenNumber: nil)
        let step2 = GuidanceStep(index: 0, total: 1, instruction: "do it", rawPointCoordinate: CGPoint(x: 10, y: 20), elementLabel: "test", screenNumber: nil)
        let step3 = GuidanceStep(index: 0, total: 1, instruction: "do something else", rawPointCoordinate: CGPoint(x: 10, y: 20), elementLabel: "test", screenNumber: nil)

        #expect(step1 == step2)
        #expect(step1 != step3)
    }
}
