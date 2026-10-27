import Testing
@testable import WaveCore

struct EvalArgumentsTests {
    @Test func defaults() throws {
        let parsed = try EvalArguments.parse(["list.tsv"])
        #expect(parsed.listPath == "list.tsv")
        #expect(parsed.split == .tune)
        #expect(parsed.offsetMs == 0 && parsed.latencyMs == 0)
        #expect(parsed.renderHz == 60 && parsed.windowMs == 70 && parsed.seed == 1)
        #expect(parsed.jobs == nil && parsed.maxFiles == nil)
        #expect(!parsed.json && !parsed.perFile && parsed.overrides.isEmpty && parsed.unions.isEmpty)
    }

    @Test func allOptions() throws {
        let parsed = try EvalArguments.parse([
            "--json", "--per-file", "--split", "heldout", "--offset-ms", "-20", "--latency-ms=12.5",
            "--tracker", "alpha=0.3", "--tracker=lockHits=6", "--union", "steady=disco,pop", "--render-hz", "120",
            "--seed", "7", "--window-ms", "50", "--skip-seconds", "5", "--jobs", "3", "--max-files", "10",
            "list.tsv",
        ])
        #expect(parsed.json && parsed.perFile)
        #expect(parsed.split == .heldout)
        #expect(parsed.offsetMs == -20 && parsed.latencyMs == 12.5)
        #expect(parsed.overrides == [.init(name: "alpha", value: 0.3), .init(name: "lockHits", value: 6)])
        #expect(parsed.unions == [.init(name: "steady", groups: ["disco", "pop"])])
        #expect(parsed.renderHz == 120 && parsed.seed == 7 && parsed.windowMs == 50 && parsed.skipSeconds == 5)
        #expect(parsed.jobs == 3 && parsed.maxFiles == 10)
        #expect(parsed.listPath == "list.tsv")
    }

    /// Режимы B0: записи владельца с петлей и сбросами, пары, сбросы на GTZAN; несовместимые сочетания
    /// это ошибка, а не молча другой прогон.
    @Test func ownerPairsAndResetOptions() throws {
        let defaults = try EvalArguments.parse(["list.tsv"])
        #expect(!defaults.owner && defaults.pairs == nil && defaults.resetEvery == nil && defaults.loop == 1)
        #expect(!defaults.resetTrackerOnly)
        #expect(defaults.chainConfig(forFile: "a.wav").resetInterval == nil)

        let owner = try EvalArguments.parse(["--owner", "--loop", "4", "--reset-every", "7.3", "--tracker", "lockHits=4", "owner.tsv"])
        #expect(owner.owner && owner.loop == 4 && owner.resetEvery == 7.3)
        var meta = RhythmLog.Meta(outputLatency: 0.134, syncOffset: -0.03, sampleRate: 44_100, renderPeriod: 1.0 / 50)
        meta.endReason = .complete
        let config = owner.ownerConfig(for: meta)
        #expect(config.outputLatency == 0.134 && config.syncOffset == -0.03 && config.renderRate == 50)
        #expect(config.resetInterval == 7.3 && config.resetAnalyzer)
        #expect(config.trackerParameters.lockHits == 4 && config.seed == 1)

        let only = try EvalArguments.parse(["--reset-every=12", "--reset-tracker-only", "list.tsv"])
        #expect(only.chainConfig(forFile: "a.wav").resetInterval == 12)
        #expect(!only.chainConfig(forFile: "a.wav").resetAnalyzer)

        #expect(try EvalArguments.parse(["--pairs", "4", "list.tsv"]).pairs == 4)
        #expect(throws: EvalArguments.Error.conflictingOptions("--owner", "--pairs")) {
            try EvalArguments.parse(["--owner", "--pairs", "4", "list.tsv"])
        }
        #expect(throws: EvalArguments.Error.conflictingOptions("--pairs", "--reset-every")) {
            try EvalArguments.parse(["--pairs", "4", "--reset-every", "7", "list.tsv"])
        }
        #expect(throws: EvalArguments.Error.conflictingOptions("--loop", "a GTZAN list (use --owner)")) {
            try EvalArguments.parse(["--loop", "2", "list.tsv"])
        }
        #expect(throws: EvalArguments.Error.missingValue("--reset-every")) {
            try EvalArguments.parse(["--reset-tracker-only", "list.tsv"])
        }
        #expect(throws: EvalArguments.Error.invalidValue(option: "--pairs", value: "0")) {
            try EvalArguments.parse(["--pairs", "0", "list.tsv"])
        }
        #expect(throws: EvalArguments.Error.invalidValue(option: "--reset-every", value: "0.0")) {
            try EvalArguments.parse(["--reset-every", "0", "list.tsv"])
        }
    }

    /// Склейка пар через тишину (`--pair-gap`, смена трека у всего звука системы) и паузы с тишиной вместо
    /// сбросов (`--pause`, пауза плеера, во время которой захват получает нули): нужные к ним режимы
    /// обязательны, несовместимые сочетания это ошибка.
    @Test func pairGapAndPauseOptions() throws {
        let defaults = try EvalArguments.parse(["list.tsv"])
        #expect(defaults.pairGap == nil && defaults.pause == nil)

        let gap = try EvalArguments.parse(["--pairs", "28", "--pair-gap", "1", "list.tsv"])
        #expect(gap.pairs == 28 && gap.pairGap == 1)
        #expect(throws: EvalArguments.Error.missingValue("--pairs")) {
            try EvalArguments.parse(["--pair-gap", "1", "list.tsv"])
        }
        #expect(throws: EvalArguments.Error.invalidValue(option: "--pair-gap", value: "0.0")) {
            try EvalArguments.parse(["--pairs", "4", "--pair-gap", "0", "list.tsv"])
        }

        let pause = try EvalArguments.parse(["--reset-every", "7.3", "--pause", "2", "list.tsv"])
        #expect(pause.resetEvery == 7.3 && pause.pause == 2)
        // Паузы заменяют сбросы: цепочка не сбрасывается, тишину в звук вставляет `EvalPauses`.
        #expect(pause.chainConfig(forFile: "a.wav").resetInterval == nil)
        #expect(throws: EvalArguments.Error.missingValue("--reset-every")) {
            try EvalArguments.parse(["--pause", "2", "list.tsv"])
        }
        #expect(throws: EvalArguments.Error.conflictingOptions("--pause", "--reset-tracker-only")) {
            try EvalArguments.parse(["--reset-every", "7", "--pause", "2", "--reset-tracker-only", "list.tsv"])
        }
        #expect(throws: EvalArguments.Error.conflictingOptions("--owner", "--pause")) {
            try EvalArguments.parse(["--owner", "--reset-every", "7", "--pause", "2", "owner.tsv"])
        }
        #expect(throws: EvalArguments.Error.invalidValue(option: "--pause", value: "-1.0")) {
            try EvalArguments.parse(["--reset-every", "7", "--pause", "-1", "list.tsv"])
        }
    }

    @Test func unionGroupsMustExist() throws {
        let parsed = try EvalArguments.parse(["--union", "steady=disco,pop", "x.tsv"])
        try parsed.validateUnions(knownGroups: ["disco", "pop", "jazz"])
        #expect(throws: EvalArguments.Error.unknownUnionGroup(union: "steady", group: "pop")) {
            try parsed.validateUnions(knownGroups: ["disco"])
        }
    }

    @Test func listMayComeFirst() throws {
        let parsed = try EvalArguments.parse(["list.tsv", "--json"])
        #expect(parsed.listPath == "list.tsv" && parsed.json)
    }

    @Test func helpNeedsNoList() throws {
        #expect(try EvalArguments.parse(["--help"]).help)
    }

    @Test func rejectsBadInput() {
        #expect(throws: EvalArguments.Error.missingList) { try EvalArguments.parse([]) }
        #expect(throws: EvalArguments.Error.unknownOption("--bogus")) { try EvalArguments.parse(["--bogus", "x.tsv"]) }
        #expect(throws: EvalArguments.Error.missingValue("--split")) { try EvalArguments.parse(["x.tsv", "--split"]) }
        #expect(throws: EvalArguments.Error.invalidValue(option: "--split", value: "some")) {
            try EvalArguments.parse(["--split", "some", "x.tsv"])
        }
        #expect(throws: EvalArguments.Error.invalidValue(option: "--offset-ms", value: "nan")) {
            try EvalArguments.parse(["--offset-ms", "nan", "x.tsv"])
        }
        #expect(throws: EvalArguments.Error.invalidValue(option: "--jobs", value: "0")) {
            try EvalArguments.parse(["--jobs", "0", "x.tsv"])
        }
        #expect(throws: EvalArguments.Error.extraArgument("y.tsv")) { try EvalArguments.parse(["x.tsv", "y.tsv"]) }
        #expect(throws: EvalArguments.Error.unknownTrackerParameter("speed")) {
            try EvalArguments.parse(["--tracker", "speed=1", "x.tsv"])
        }
        // Целое поле не берет дробное значение.
        #expect(throws: EvalArguments.Error.invalidValue(option: "--tracker", value: "lockHits=2.5")) {
            try EvalArguments.parse(["--tracker", "lockHits=2.5", "x.tsv"])
        }
        #expect(throws: EvalArguments.Error.invalidValue(option: "--tracker", value: "alpha=-3")) {
            try EvalArguments.parse(["--tracker", "alpha=-3", "x.tsv"])
        }
        #expect(throws: EvalArguments.Error.invalidValue(option: "--tracker", value: "alpha=inf")) {
            try EvalArguments.parse(["--tracker", "alpha=inf", "x.tsv"])
        }
        #expect(throws: EvalArguments.Error.invalidValue(option: "--tracker", value: "alpha")) {
            try EvalArguments.parse(["--tracker", "alpha", "x.tsv"])
        }
    }

    /// Каждое имя из `names` задает свое поле, и больше ничего не меняется.
    @Test func everyTrackerNameSetsItsOwnField() {
        let defaults = BeatTracker.Parameters()
        for name in BeatTracker.Parameters.names {
            var changed = defaults
            // 3 бывает и значением по умолчанию (`raceVotes`), тогда пробуется 7.
            var value = 3.0
            var accepted = changed.set(name, to: value)
            if changed == defaults {
                value = 7
                accepted = changed.set(name, to: value)
            }
            #expect(accepted)
            #expect(changed != defaults, "\(name) changed nothing")
            var again = changed
            _ = again.set(name, to: value)
            #expect(again == changed)
        }
        var probe = defaults
        let accepted = probe.set("nope", to: 1)
        #expect(!accepted)
        #expect(probe == defaults)
    }

    @Test func chainConfigAppliesEverything() throws {
        let parsed = try EvalArguments.parse([
            "--offset-ms", "-20", "--latency-ms", "10", "--render-hz", "120", "--tracker", "alpha=0.5",
            "--tracker", "lockHits=7", "x.tsv",
        ])
        let config = parsed.chainConfig(forFile: "a.wav")
        #expect(config.syncOffset == -0.020)
        #expect(config.outputLatency == 0.010)
        #expect(config.renderRate == 120)
        #expect(config.trackerParameters.alpha == 0.5 && config.trackerParameters.lockHits == 7)
        #expect(config.trackerParameters.beta == BeatTracker.Parameters().beta)
    }

    @Test func seedDependsOnFileNameOnly() throws {
        let parsed = try EvalArguments.parse(["x.tsv"])
        #expect(parsed.chainConfig(forFile: "a.wav").seed == parsed.chainConfig(forFile: "a.wav").seed)
        #expect(parsed.chainConfig(forFile: "a.wav").seed != parsed.chainConfig(forFile: "b.wav").seed)
        let other = try EvalArguments.parse(["--seed", "2", "x.tsv"])
        #expect(other.chainConfig(forFile: "a.wav").seed != parsed.chainConfig(forFile: "a.wav").seed)
        // FNV-1a 64 бит: известные значения.
        #expect(EvalArguments.fnv1a("") == 0xCBF2_9CE4_8422_2325)
        #expect(EvalArguments.fnv1a("a") == 0xAF63_DC4C_8601_EC8C)
    }
}

struct EvalListTests {
    @Test func parsesThreeAndFourColumns() throws {
        let text = "# comment\n/a.wav\t/a.beats\tblues\n\n/b.wav\t/b.beats\tjazz\theldout\n/c.wav\t/c.beats\tjazz\ttune\n"
        let entries = try EvalList.parse(text)
        #expect(entries == [
            .init(wavPath: "/a.wav", annotationPath: "/a.beats", group: "blues", heldout: false),
            .init(wavPath: "/b.wav", annotationPath: "/b.beats", group: "jazz", heldout: true),
            .init(wavPath: "/c.wav", annotationPath: "/c.beats", group: "jazz", heldout: false),
        ])
    }

    @Test func reportsBadLines() {
        #expect(throws: EvalList.Error.malformed(line: 2)) { try EvalList.parse("/a\t/b\tg\n/a\t/b\n") }
        #expect(throws: EvalList.Error.malformed(line: 1)) { try EvalList.parse("/a\t\tg\n") }
        #expect(throws: EvalList.Error.unknownSplit(line: 1, value: "test")) { try EvalList.parse("/a\t/b\tg\ttest\n") }
    }

    @Test func selectsSplitsAndLimit() {
        let entries = (0..<10).map {
            EvalList.Entry(wavPath: "\($0)", annotationPath: "", group: "g", heldout: $0 % 5 == 4)
        }
        #expect(EvalList.select(entries, split: .all, limit: nil).count == 10)
        #expect(EvalList.select(entries, split: .heldout, limit: nil).map(\.wavPath) == ["4", "9"])
        #expect(EvalList.select(entries, split: .tune, limit: nil).count == 8)
        #expect(EvalList.select(entries, split: .tune, limit: 3).map(\.wavPath) == ["0", "1", "2"])
    }

    @Test func parsesAnnotations() {
        let text = "0.217\t3\n0.695\t4\r\n1.173\t1\n\n# note\nbad\t2\n-1.0\t1\n0.100 2\n"
        #expect(BeatAnnotations.parse(text) == [0.100, 0.217, 0.695, 1.173])
        #expect(BeatAnnotations.parse("").isEmpty)
    }
}
