import ApplicationServices
import Foundation
import LocalAuthentication
import Security
import SprekrCore
import SwiftUI
import Testing
@testable import SprekrApp

@Suite("Product logic")
struct ProductLogicTests {
    @Test func rebrandPreservesLegacyDataAndMacOSIdentityAnchors() {
        #expect(SprekrIdentity.displayName == "Sprekr")
        #expect(SprekrIdentity.executableName == "Sprekr")
        #expect(SprekrIdentity.Compatibility.bundleIdentifier == "com.klimtalks.app")
        #expect(SprekrIdentity.Compatibility.developmentBundleIdentifier == "com.klimtalks.app.development")
        #expect(SprekrIdentity.Compatibility.keychainService == "com.klimtalks.app")
        #expect(SprekrIdentity.Compatibility.settingsKey == "com.klimtalks.app.settings")
        #expect(SprekrIdentity.Compatibility.applicationSupportDirectoryName == "Klim Talks")
    }

    @Test func onboardingFinishSequenceStaysShortUsefulAndDashFree() {
        let durationMilliseconds = OnboardingFinishPolicy.progressStepCount
            * OnboardingFinishPolicy.progressStepMilliseconds

        #expect((5_000...10_000).contains(durationMilliseconds))
        #expect(OnboardingFinishPolicy.automaticTipStepInterval > 0)
        #expect(OnboardingFinishPolicy.tips.count >= 4)
        #expect(OnboardingFinishPolicy.tips.allSatisfy { !$0.contains("-") })
        #expect(OnboardingFinishPolicy.tips.contains { $0.contains("Escape") })
        #expect(OnboardingFinishPolicy.tips.contains { $0.contains("private") })
    }

    @Test func modelOnboardingActionsMatchEveryInstallState() {
        #expect(OnboardingReadinessPolicy.modelAction(for: .notInstalled) == .install)
        #expect(OnboardingReadinessPolicy.modelAction(for: .checking) == .none)
        #expect(
            OnboardingReadinessPolicy.modelAction(
                for: .downloading(progress: 0.4, detail: "Downloading")
            ) == .none
        )
        #expect(OnboardingReadinessPolicy.modelAction(for: .installed(bytes: 483_000_000)) == .continueFlow)
        #expect(OnboardingReadinessPolicy.modelAction(for: .failed(message: "Offline")) == .retry)
        #expect(!OnboardingReadinessPolicy.canContinueFromModel(.notInstalled))
        #expect(OnboardingReadinessPolicy.canContinueFromModel(.installed(bytes: 483_000_000)))
    }

    @Test func modelDownloadBlocksOnlyAKnownStorageShortage() {
        #expect(ModelDownloadPolicy.storageFailureMessage(availableBytes: nil) == nil)
        #expect(ModelDownloadPolicy.storageFailureMessage(availableBytes: 2_000_000_000) == nil)
        #expect(
            ModelDownloadPolicy.storageFailureMessage(availableBytes: 100_000_000)
                == "Download failed. Your Mac doesn’t have enough free storage. Free at least 1 GB and try again."
        )
    }

    @Test func talkKeyReadinessExplainsEveryBlockedState() {
        #expect(OnboardingReadinessPolicy.blockingTalkKeyMessage(
            hotkeyRegistered: true,
            conflictMessage: nil,
            isRecordingShortcut: true
        ) == "Finish choosing your talk key before continuing.")
        #expect(OnboardingReadinessPolicy.blockingTalkKeyMessage(
            hotkeyRegistered: true,
            conflictMessage: "Choose different keys.",
            isRecordingShortcut: false
        ) == "Choose different keys.")
        #expect(OnboardingReadinessPolicy.blockingTalkKeyMessage(
            hotkeyRegistered: false,
            conflictMessage: nil,
            isRecordingShortcut: false
        ) == "Sprekr could not activate your talk controls yet. Check Accessibility and try again.")
        #expect(OnboardingReadinessPolicy.canContinueFromTalkKeys(
            hotkeyRegistered: true,
            conflictMessage: nil,
            isRecordingShortcut: false
        ))
    }

    @Test func bundledAcknowledgementsTableParsesIntoVisibleRows() {
        let source = """
        # Third-party notices

        | Component | Use | License / attribution |
        | --- | --- | --- |
        | FluidAudio `v0.15.5` | Local audio runtime | Apache-2.0 |
        | Onest `1.000` | Interface typography | SIL Open Font License 1.1 |

        No hosted inference service is used.
        """

        let document = AcknowledgementsDocument.parse(source)

        #expect(document.entries == [
            AcknowledgementEntry(
                component: "FluidAudio `v0.15.5`",
                use: "Local audio runtime",
                license: "Apache-2.0"
            ),
            AcknowledgementEntry(
                component: "Onest `1.000`",
                use: "Interface typography",
                license: "SIL Open Font License 1.1"
            ),
        ])
        #expect(document.closingNote == "No hosted inference service is used.")
    }

    @Test
    func oldSettingsDecodeWithSafeCurrentDefaults() throws {
        let data = Data(#"{"onboardingCompleted":true,"showInDock":false}"#.utf8)
        let settings = try JSONDecoder().decode(SprekrSettings.self, from: data)

        #expect(settings.onboardingCompleted)
        #expect(!settings.showInDock)
        #expect(settings.launchAtLogin)
        #expect(settings.smartFormatting)
        #expect(settings.shortcut == .standard)
        #expect(settings.holdShortcut == .fnGlobe)
        #expect(settings.toggleShortcut == .optionSpace)
        #expect(settings.learnFromCorrections)
    }

    @Test
    func legacyToggleShortcutMigratesWithoutCreatingAConflict() throws {
        let data = Data(#"{"dictationMode":"Toggle to talk","shortcut":{"keyCode":63,"modifierFlags":8388608,"displayName":"Fn / Globe"}}"#.utf8)
        let settings = try JSONDecoder().decode(SprekrSettings.self, from: data)

        #expect(settings.toggleShortcut == .fnGlobe)
        #expect(settings.holdShortcut == .optionSpace)
        #expect(!settings.holdShortcut.matches(settings.toggleShortcut))
    }

    @Test
    func immediateCorrectionLearnsOnlyOneStableWordReplacement() {
        #expect(
            ImmediateCorrectionEngine.detect(
                original: "De microfon werkt nu goed.",
                edited: "De microfoon werkt nu goed."
            ) == ImmediateSpellingCorrection(heard: "microfon", preferred: "microfoon")
        )
        #expect(
            ImmediateCorrectionEngine.detect(
                original: "Sprekr werkt lokael.",
                edited: "Sprekr werkt lokaal."
            ) == ImmediateSpellingCorrection(heard: "lokael", preferred: "lokaal")
        )
        #expect(
            ImmediateCorrectionEngine.detect(
                original: "Deze hele zin is fout.",
                edited: "Een andere zin is beter."
            ) == nil
        )
    }

    @Test
    func disconnectedSelectedMicrophoneFallsBackToSystemDefault() {
        #expect(
            AudioCaptureService.resolvedSelectedDeviceUID(
                "headset-1",
                availableUIDs: ["built-in", "headset-1"]
            ) == "headset-1"
        )
        #expect(
            AudioCaptureService.resolvedSelectedDeviceUID(
                "headset-1",
                availableUIDs: ["built-in"]
            ) == nil
        )
    }

    @Test
    func appearanceResolverClearsTheOverrideForSystem() {
        #expect(AppAppearanceResolver.appearanceName(for: .system) == nil)
        #expect(AppAppearanceResolver.appearanceName(for: .light) == .aqua)
        #expect(AppAppearanceResolver.appearanceName(for: .dark) == .darkAqua)
    }

    @Test
    @MainActor
    func mainHostingViewAcceptsTheFirstInactiveWindowClick() {
        let view = SprekrFirstMouseHostingView(rootView: Text("Sprekr"))
        #expect(view.acceptsFirstMouse(for: nil))
    }

    @Test
    func nonInteractiveKeychainReadExplicitlyDisablesAuthenticationUI() {
        let context = LAContext()
        let query = KeychainStore.dataQuery(
            account: "history.encryption.key",
            authenticationContext: context,
            allowingUserInteraction: false
        )
        #expect(
            (query[kSecUseAuthenticationUI as String] as? String)
                == KeychainStore.authenticationUIFailValue
        )
    }

    @Test
    func interactiveKeychainReadAllowsTheOwnerPrompt() {
        let context = LAContext()
        let query = KeychainStore.dataQuery(
            account: "history.encryption.key",
            authenticationContext: context,
            allowingUserInteraction: true
        )
        #expect(query[kSecUseAuthenticationUI as String] == nil)
    }

    @Test
    func unlockedKeychainDataIsReusedForTheLifetimeOfTheApp() {
        let cache = KeychainDataCache()
        let key = Data([0x4b, 0x6c, 0x69, 0x6d])

        #expect(cache.data(for: "history.encryption.key") == nil)
        cache.store(key, for: "history.encryption.key")
        #expect(cache.data(for: "history.encryption.key") == key)
        #expect(cache.data(for: "dictionary.encryption.key") == nil)
    }

    @Test
    func certificateBoundStoresUseVersion2AndNeverReplaceAMissingExistingKey() {
        #expect(KeychainAccountPolicy.activeAccount(
            baseAccount: "history.encryption.key",
            certificateBound: true
        ) == "history.encryption.key.v2")
        #expect(KeychainAccountPolicy.activeAccount(
            baseAccount: "history.encryption.key",
            certificateBound: false
        ) == "history.encryption.key")

        #expect(KeychainMigrationPolicy.decision(
            certificateBound: true,
            activeKeyExists: false,
            legacyKeyExists: true,
            encryptedDataExists: true
        ) == .copyLegacyToVersion2)
        #expect(KeychainMigrationPolicy.decision(
            certificateBound: true,
            activeKeyExists: false,
            legacyKeyExists: false,
            encryptedDataExists: true
        ) == .rejectMissingKey)
        #expect(KeychainMigrationPolicy.decision(
            certificateBound: true,
            activeKeyExists: false,
            legacyKeyExists: false,
            encryptedDataExists: false
        ) == .createActive)
        #expect(KeychainMigrationPolicy.decision(
            certificateBound: true,
            activeKeyExists: true,
            legacyKeyExists: true,
            encryptedDataExists: true
        ) == .useActive)
    }

    @Test
    func privateDataPermissionsAreOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sprekr-permissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFilePermissions.ensureDirectory(root)
        let file = root.appendingPathComponent("history.enc")
        try Data("fixture".utf8).write(to: file)
        try PrivateFilePermissions.secureFile(file)

        let directoryMode = (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue
        let fileMode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(directoryMode == 0o700)
        #expect(fileMode == 0o600)
    }

    @Test
    func plaintextHistoryExportRequiresAnExplicitWarning() {
        #expect(HistoryExportPolicy.warning.contains("readable plaintext"))
        #expect(HistoryExportPolicy.warning.contains("not encrypted"))
        #expect(HistoryExportPolicy.warning.contains("every exported transcript"))
    }

    @Test
    func dutchQuestionGetsAQuestionMark() {
        #expect(
            TranscriptFormatter.format("Waarom werkt dit lokaal.", language: .dutch)
                == "Waarom werkt dit lokaal?"
        )
    }

    @Test
    func spokenLayoutCommandsProduceStableBullets() {
        let formatted = TranscriptFormatter.format(
            "Taken nieuwe regel bullet point appels bullet point peren.",
            language: .automatic
        )
        #expect(formatted == "Taken\n\n• appels\n\n• peren.")
    }

    @Test
    func spokenNumberedParagraphMarkersBecomeBlankLines() {
        #expect(
            TranscriptFormatter.format(
                "Alinea 1. De microfoon werkt goed en blijft lokaal. Alinea 2. De sidebar blijft rustig en overzichtelijk.",
                language: .dutch
            ) == "De microfoon werkt goed en blijft lokaal.\n\nDe sidebar blijft rustig en overzichtelijk."
        )
        #expect(
            TranscriptFormatter.format(
                "Paragraph one: The microphone stays local. Paragraph two: The sidebar remains clear.",
                language: .automatic
            ) == "The microphone stays local.\n\nThe sidebar remains clear."
        )
    }

    @Test
    func paragraphReferencesInsideOrdinarySentencesStayVisible() {
        #expect(
            TranscriptFormatter.format(
                "Lees alinea 2 van het contract aandachtig.",
                language: .dutch
            ) == "Lees alinea 2 van het contract aandachtig."
        )
    }

    @Test
    func longDictationSplitsAtAClearTopicTransition() {
        let transcript = [
            "De microfoon neemt tijdens iedere lange opname mijn stem duidelijk en volledig op.",
            "Alle audio blijft tijdens de verwerking veilig en uitsluitend lokaal op deze Mac.",
            "Het lokale audiomodel zet iedere zin daarna zonder een externe server om in tekst.",
            "Daarnaast wil ik de navigatie van de applicatie apart en rustig kunnen beoordelen.",
            "De sidebar moet daarom in iedere sectie dezelfde knoppen en dezelfde volgorde tonen.",
            "Die navigatie blijft ook op smallere vensters overzichtelijk en direct bruikbaar voor iedereen.",
        ].joined(separator: " ")
        let formatted = TranscriptFormatter.format(transcript, language: .dutch)

        #expect(formatted.contains("om in tekst.\n\nDaarnaast wil ik de navigatie"))
    }

    @Test
    func veryLongDictationDetectsTwoLocallyCohesiveTopics() {
        let transcript = [
            "De microfoon registreert tijdens uitgebreide dicteersessies ieder gesproken woord nauwkeurig in een tijdelijk audiobestand.",
            "Dat audiobestand blijft lokaal terwijl de microfoon alle zachte en harde stemniveaus zorgvuldig opvangt.",
            "De microfoon stuurt de lokale audio vervolgens rechtstreeks naar het ingebouwde spraakmodel voor verwerking.",
            "Na de verwerking verdwijnt de tijdelijke audio en bewaart de microfoon uitsluitend de voltooide transcriptie.",
            "De sidebar organiseert ondertussen alle navigatieknoppen in een vaste verticale kolom naast de hoofdinhoud.",
            "Elke navigatieknop in de sidebar opent direct een eigen sectie zonder extra klik of vertraging.",
            "De sidebar behoudt haar compacte navigatie ook wanneer het venster naar de minimale breedte wordt aangepast.",
            "Zo blijft iedere navigatieoptie duidelijk bereikbaar terwijl de hoofdinhoud rustig en overzichtelijk op haar plaats blijft.",
        ].joined(separator: " ")
        let formatted = TranscriptFormatter.format(transcript, language: .dutch)

        #expect(formatted.contains("voltooide transcriptie.\n\nDe sidebar organiseert"))
    }

    @Test
    func mediumCohesiveDictationIsNotSplitWithoutARealBoundary() {
        let transcript = [
            "Het lokale project bewaart ieder projectbestand veilig en versleuteld op deze Mac voor later gebruik.",
            "Binnen het project blijft elke projectnotitie beschikbaar zonder verbinding met een externe cloudserver of dienst.",
            "De projectgeschiedenis toont alle eerdere projectteksten overzichtelijk op datum en op het juiste tijdstip.",
            "Iedere projecttekst kan vanuit dezelfde projectgeschiedenis opnieuw worden gekopieerd zonder de oorspronkelijke inhoud te wijzigen.",
        ].joined(separator: " ")
        let formatted = TranscriptFormatter.format(transcript, language: .dutch)

        #expect(!formatted.contains("\n\n"))
    }

    @Test
    func clearEnumeratorsBecomeLabelledParagraphs() {
        let formatted = TranscriptFormatter.format(
            "Ten eerste, koffie. Ten tweede, thee.",
            language: .dutch
        )
        #expect(formatted == "Ten eerste koffie.\n\nTen tweede thee.")
    }

    @Test
    func conversationalEnumeratorsKeepTheirWordsWithoutPerfectPunctuation() {
        let formatted = TranscriptFormatter.format(
            "Ik heb twee verbeteringen. Dus en ten eerste, de tekst moet meer ademruimte krijgen en ten tweede, de spraaktoets mag niet starten. Daarna gebruik ik klimtalks opnieuw.",
            language: .dutch
        )

        #expect(formatted == [
            "Ik heb 2 verbeteringen.",
            "Ten eerste de tekst moet meer ademruimte krijgen.",
            "En ten tweede de spraaktoets mag niet starten.",
            "Daarna gebruik ik klimtalks opnieuw.",
        ].joined(separator: "\n\n"))
    }

    @Test
    func ordinalRegressionMatchesTheRequestedEditorialStyle() {
        let transcript = "Zou je een aantal dingen voor mij kunnen doen? Ten eerste zou je mij kunnen vertellen wat je nodig hebt ten tweede zou je mij even kunnen helpen en begeleiden met het online zetten van dit project en ten derde zou je mij even een beknopte samenvatting kunnen geven van wat je daar hebt gedaan"

        #expect(TranscriptFormatter.format(transcript, language: .dutch) == [
            "Zou je een aantal dingen voor mij kunnen doen?",
            "Ten eerste zou je mij kunnen vertellen wat je nodig hebt.",
            "Ten tweede zou je mij even kunnen helpen en begeleiden met het online zetten van dit project.",
            "En ten derde zou je mij even een beknopte samenvatting kunnen geven van wat je daar hebt gedaan.",
        ].joined(separator: "\n\n"))
    }

    @Test
    func englishOrdinalsBecomeLabelledParagraphsAndInvalidSequencesStayProse() {
        #expect(TranscriptFormatter.format(
            "Please do two things. First tell me what you need and second explain the next step",
            language: .english
        ) == [
            "Please do 2 things.",
            "First tell me what you need.",
            "And second explain the next step.",
        ].joined(separator: "\n\n"))

        let duplicate = "First explain speed. First explain privacy. Second explain safety."
        let outOfOrder = "First explain speed. Third explain privacy."
        #expect(TranscriptFormatter.format(duplicate, language: .english) == duplicate)
        #expect(TranscriptFormatter.format(outOfOrder, language: .english) == outOfOrder)
    }

    @Test
    func shortOrdinalIntroIsNotTurnedIntoABullet() {
        let transcript = "Oké, ten eerste zou je dit voor mij kunnen doen? Zou je duidelijk kunnen opnoemen wat je nodig hebt en ten tweede zou je duidelijk kunnen laten weten wat het is"

        let formatted = TranscriptFormatter.format(transcript, language: .dutch)
        #expect(formatted == [
            "Oké.",
            "Ten eerste zou je dit voor mij kunnen doen? Zou je duidelijk kunnen opnoemen wat je nodig hebt.",
            "En ten tweede zou je duidelijk kunnen laten weten wat het is.",
        ].joined(separator: "\n\n"))
        #expect(!formatted.contains("•"))
    }

    @Test
    func spokenPointNumbersBecomeSeparateLabelledParagraphs() {
        let transcript = "Zou je even het volgende voor mij kunnen onderzoeken? Dat zijn drie punten. Punt 1: Hoe kan het zijn dat jij nog steeds niet zo heel goed weet hoe je moet format? Punt 2, dit is een testspraakopname. Zoals je ziet, heeft hij alles nog steeds in één blok gedaan. Punt 3, onderzoek dit goed en zorg ervoor dat hij dit echt in alineas gaat doen en dat hij hier heel intelligent in kan nadenken?"

        #expect(
            TranscriptFormatter.format(transcript, language: .dutch) == [
                "Zou je even het volgende voor mij kunnen onderzoeken? Dat zijn 3 punten.",
                "Punt 1: Hoe kan het zijn dat jij nog steeds niet zo heel goed weet hoe je moet format?",
                "Punt 2: dit is een testspraakopname. Zoals je ziet, heeft hij alles nog steeds in 1 blok gedaan.",
                "Punt 3: onderzoek dit goed en zorg ervoor dat hij dit echt in alineas gaat doen en dat hij hier heel intelligent in kan nadenken?",
            ].joined(separator: "\n\n")
        )
    }

    @Test
    func writtenPointNumbersAndConnectorsWorkWithoutPerfectPunctuation() {
        #expect(
            TranscriptFormatter.format(
                "Ik heb drie punten punt één snelheid en punt twee privacy en punt drie eenvoud.",
                language: .dutch
            ) == [
                "Ik heb 3 punten",
                "Punt 1: snelheid",
                "Punt 2: privacy",
                "Punt 3: eenvoud.",
            ].joined(separator: "\n\n")
        )

        #expect(
            TranscriptFormatter.format(
                "Punt nummer 1 snelheid. Punt nummer 2 privacy.",
                language: .dutch
            ) == "Punt nummer 1: snelheid.\n\nPunt nummer 2: privacy."
        )

        #expect(
            TranscriptFormatter.format(
                "There are three points. Point number one, speed. And point number two privacy. Point three: clarity.",
                language: .automatic
            ) == [
                "There are 3 points.",
                "Point number 1: speed.",
                "Point number 2: privacy.",
                "Point 3: clarity.",
            ].joined(separator: "\n\n")
        )
    }

    @Test
    func unsafePointReferencesRemainOrdinaryText() {
        let samples = [
            "Zie punt 1 van het contract.",
            "Punt 1 gaat over snelheid. Punt 1 gaat over privacy. Punt 2 gaat over eenvoud.",
            "Punt 1 gaat over snelheid. Punt 3 gaat over privacy. Punt 2 gaat over eenvoud.",
        ]
        for sample in samples {
            #expect(TranscriptFormatter.format(sample, language: .dutch) == sample)
        }
    }

    @Test
    func clearListIntentCreatesParallelBullets() {
        #expect(
            TranscriptFormatter.format(
                "Zou jij van de volgende punten even een blog kunnen schrijven over poesjes, over leeuwen en over honden?",
                language: .dutch
            ) == "Zou jij van de volgende punten even een blog kunnen schrijven:\n\n• over poesjes\n\n• over leeuwen\n\n• over honden?"
        )

        #expect(
            TranscriptFormatter.format(
                "Zou jij van de volgende punten even een blog kunnen schrijven over poesjes, over leeuwen en over honden.",
                language: .dutch
            ) == "Zou jij van de volgende punten even een blog kunnen schrijven:\n\n• over poesjes\n\n• over leeuwen\n\n• over honden?"
        )

        #expect(
            TranscriptFormatter.format(
                "De volgende onderwerpen zijn katten, leeuwen en honden.",
                language: .dutch
            ) == "De volgende onderwerpen zijn:\n\n• katten\n\n• leeuwen\n\n• honden."
        )

        #expect(
            TranscriptFormatter.format(
                "Please cover the following topics: cats, lions and dogs.",
                language: .automatic
            ) == "Please cover the following topics:\n\n• cats\n\n• lions\n\n• dogs."
        )
    }

    @Test
    func requestedTrueListUsesRoundBulletsWithBlankLines() {
        let transcript = "Hier even een aantal punten waar je heel goed op moet letten: De schrijfstijl, De copywriting, De manier waarop je praat, De UI en De UX"

        #expect(TranscriptFormatter.format(transcript, language: .dutch) == [
            "Hier even een aantal punten waar je heel goed op moet letten:",
            "• De schrijfstijl",
            "• De copywriting",
            "• De manier waarop je praat",
            "• De UI",
            "• De UX",
        ].joined(separator: "\n\n"))
    }

    @Test
    func uncertainCommaSeriesRemainOrdinaryText() {
        let samples = [
            "Ik schrijf graag over poesjes, leeuwen en honden.",
            "De volgende onderwerpen zijn katten en honden.",
            "De volgende punten zijn een uitgebreide uitleg met veel verschillende woorden over de volledige lokale verwerking, een tweede uitgebreide uitleg met opnieuw veel woorden omdat dit een gewone zin is en een derde uitgebreide uitleg die bewust te lang is voor een veilig lijstonderdeel.",
        ]
        for sample in samples {
            #expect(TranscriptFormatter.format(sample, language: .dutch) == sample)
        }
    }

    @Test
    func aSingleEnumeratorInOrdinaryTextIsLeftAlone() {
        #expect(
            TranscriptFormatter.format(
                "Ik wil ten eerste begrijpen waarom dit gebeurt.",
                language: .dutch
            ) == "Ik wil ten eerste begrijpen waarom dit gebeurt."
        )
    }

    @Test
    func mediumDictationSplitsAtAnExplicitTransition() {
        let transcript = [
            "De microfoon neemt ieder gesproken woord rustig en volledig lokaal op deze Mac op.",
            "Het audiomodel verwerkt daarna alle zinnen zonder een externe server of cloudverbinding.",
            "En vervolgens wil ik de instellingen voor beide onafhankelijke spraaktoetsen duidelijk kunnen wijzigen.",
            "De gekozen toetsen moeten na iedere wijziging direct betrouwbaar en zonder conflict blijven werken.",
        ].joined(separator: " ")

        let formatted = TranscriptFormatter.format(transcript, language: .dutch)
        #expect(formatted.contains("cloudverbinding.\n\nEn vervolgens wil ik"))
    }

    @Test
    func veryLongBlocksGetANaturalReadableFallbackBreak() {
        let sentences = (1...6).map { index in
            "Onderdeel \(index) beschrijft deze uitgebreide lokale dicteerfunctie met voldoende duidelijke woorden voor een rustige leesbare uitleg zonder onderwerpsovergang."
        }
        let formatted = TranscriptFormatter.format(
            sentences.joined(separator: " "),
            language: .dutch
        )

        #expect(formatted.contains("\n\n"))
    }

    @Test
    func twoVeryLongSentencesSplitOnlyAtTheirNaturalBoundary() {
        let first = "De eerste uitleg "
            + (1...40).map { "lokaal\($0)" }.joined(separator: " ") + "."
        let second = "De tweede uitleg "
            + (1...40).map { "veilig\($0)" }.joined(separator: " ") + "."
        #expect(
            TranscriptFormatter.format(first + " " + second, language: .dutch)
                == first + "\n\n" + second
        )

        let oneSentence = "Deze ene zin "
            + (1...90).map { "woord\($0)" }.joined(separator: " ") + "."
        #expect(
            TranscriptFormatter.format(oneSentence, language: .dutch) == oneSentence
        )
    }

    @Test
    func sprekrUsesItsCanonicalBrandSpellingOnlyInSafeContexts() {
        #expect(
            TranscriptFormatter.format(
                "Ik gebruik sprekr en daarna SPREKR opnieuw.",
                language: .automatic
            ) == "Ik gebruik Sprekr en daarna Sprekr opnieuw."
        )
        #expect(
            TranscriptFormatter.format(
                "Open spreker, gebruik spreker en probeer de spreker-app.",
                language: .dutch
            ) == "Open Sprekr, gebruik Sprekr en probeer de Sprekr-app."
        )
        #expect(
            TranscriptFormatter.format(
                "De spreker op het podium gebruikt een luidspreker.",
                language: .dutch
            ) == "De spreker op het podium gebruikt een luidspreker."
        )
        #expect(
            TranscriptFormatter.format(
                "Ik gebruik klimtalks en daarna KLIM TALKS opnieuw.",
                language: .automatic
            ) == "Ik gebruik klimtalks en daarna KLIM TALKS opnieuw."
        )
    }

    @Test
    func ordinaryUseOfTheWordPuntIsNotTreatedAsACommand() {
        #expect(
            TranscriptFormatter.format("Ik maak een punt.", language: .dutch)
                == "Ik maak een punt."
        )
    }

    @Test
    func explicitTerminalPunctuationCommandIsApplied() {
        #expect(
            TranscriptFormatter.format("Dit is belangrijk uitroepteken", language: .dutch)
                == "Dit is belangrijk!"
        )
    }

    @Test
    func spokenDutchCardinalsBecomeConsistentDigits() {
        let cases: [(String, String)] = [
            ("honderdzevenentwintig", "127"),
            ("duizend vierhonderd en dertien", "1413"),
            ("tienduizend vierhonderddrieëntwintig euro", "10.423 euro"),
            ("twee miljoen driehonderdduizend vijf", "2.300.005"),
            ("min twaalf graden", "-12 graden"),
            ("tien komma nul vijf procent", "10,05 procent"),
        ]
        for (spoken, expected) in cases {
            #expect(SpokenNumberFormatter.format(
                spoken,
                spokenLanguage: .dutch,
                outputLanguage: .dutch
            ) == expected)
        }
    }

    @Test
    func spokenEnglishCardinalsUseEnglishOutputNotation() {
        #expect(SpokenNumberFormatter.format(
            "one hundred and twenty-seven",
            spokenLanguage: .english,
            outputLanguage: .english
        ) == "127")
        #expect(SpokenNumberFormatter.format(
            "ten thousand four hundred and twenty-three dollars",
            spokenLanguage: .english,
            outputLanguage: .english
        ) == "10,423 dollars")
        #expect(SpokenNumberFormatter.format(
            "minus twelve point zero five percent",
            spokenLanguage: .english,
            outputLanguage: .english
        ) == "-12.05 percent")
    }

    @Test
    func largeSupportedScalesConvertWhileOverflowLikePhrasesStayUntouched() {
        #expect(SpokenNumberFormatter.format(
            "negen biljoen twaalf miljoen vijf",
            spokenLanguage: .dutch,
            outputLanguage: .dutch
        ) == "9.000.012.000.005")
        #expect(SpokenNumberFormatter.format(
            "nine trillion twelve million five",
            spokenLanguage: .english,
            outputLanguage: .english
        ) == "9,000,012,000,005")

        let overflowLike = "tien miljoen biljoen"
        #expect(SpokenNumberFormatter.format(
            overflowLike,
            spokenLanguage: .dutch,
            outputLanguage: .dutch
        ) == overflowLike)
    }

    @Test
    func numberGroupingUsesTheFinalOutputLanguageFromFiveDigits() {
        #expect(SpokenNumberFormatter.format(
            "tienduizend vierhonderddrieëntwintig",
            spokenLanguage: .dutch,
            outputLanguage: .english
        ) == "10,423")
        #expect(SpokenNumberFormatter.format(
            "ten thousand four hundred twenty-three",
            spokenLanguage: .english,
            outputLanguage: .dutch
        ) == "10.423")
        #expect(SpokenNumberFormatter.format(
            "duizend vierhonderddertien en tienduizend vierhonderddrieëntwintig",
            spokenLanguage: .dutch,
            outputLanguage: .dutch
        ) == "1413 en 10.423")
    }

    @Test
    func unaccentedOneNeedsNumericContextWhileAccentedOneDoesNot() {
        #expect(SpokenNumberFormatter.format(
            "Ik zie een kat en één hond.",
            spokenLanguage: .dutch,
            outputLanguage: .dutch
        ) == "Ik zie een kat en 1 hond.")
        #expect(SpokenNumberFormatter.format(
            "een euro, een twee drie en punt een",
            spokenLanguage: .dutch,
            outputLanguage: .dutch
        ) == "1 euro, 1 2 3 en punt 1")
    }

    @Test
    func specialNumberContextsAndIdiomsRemainUntouched() {
        let samples = [
            "Bel telefoonnummer nul zes een twee drie vier.",
            "Gebruik versie twaalf punt drie.",
            "Het IP adres is een twee zeven punt nul punt nul punt een.",
            "We doen dit een voor een.",
            "Dit is een van de opties.",
            "We spreken af om tien uur.",
            "De afspraak is twaalf juli tweeduizend vierentwintig.",
        ]
        for sample in samples {
            #expect(SpokenNumberFormatter.format(
                sample,
                spokenLanguage: .dutch,
                outputLanguage: .dutch
            ) == sample)
        }

        let englishDate = "The appointment is twelve July twenty twenty-four."
        #expect(SpokenNumberFormatter.format(
            englishDate,
            spokenLanguage: .english,
            outputLanguage: .english
        ) == englishDate)
    }

    @Test
    func writtenQuantitiesAreGroupedWithoutDamagingCodesOrPhoneNumbers() {
        #expect(SpokenNumberFormatter.format(
            "Het bedrag is 10423 euro.",
            spokenLanguage: .dutch,
            outputLanguage: .dutch
        ) == "Het bedrag is 10.423 euro.")

        let protected = [
            "Gebruik code 12345.",
            "Bel telefoonnummer 31612345678.",
            "Gebruik versie 12345 voor deze test.",
        ]
        for sample in protected {
            #expect(SpokenNumberFormatter.format(
                sample,
                spokenLanguage: .dutch,
                outputLanguage: .dutch
            ) == sample)
        }
    }

    @Test
    func numbersAndSymbolsStayActiveOutsideSmartFormatting() {
        let numbered = SpokenNumberFormatter.format(
            "tienduizend euro apenstaartje",
            spokenLanguage: .dutch,
            outputLanguage: .dutch
        )
        let symbolized = SpokenSymbolFormatter.format(numbered, language: .dutch)

        #expect(numbered == "10.000 euro apenstaartje")
        #expect(symbolized == "10.000 euro @")
    }

    @Test
    func spokenSymbolRegressionUsesActualCharacters() {
        #expect(
            SpokenSymbolFormatter.format(
                "Stel je voor dat ik hardop zeg apenstaartje, slash of streepje.",
                language: .dutch
            ) == "Stel je voor dat ik hardop zeg @, / of -."
        )
        #expect(
            SpokenSymbolFormatter.format(
                "apenstaartje slash streepje plus",
                language: .automatic
            ) == "@ / - +"
        )
    }

    @Test
    func spokenSymbolsBuildNaturalEmailAddressesURLsAndPaths() {
        #expect(
            SpokenSymbolFormatter.format(
                "jibreel apenstaartje gmail punt com",
                language: .dutch
            ) == "jibreel@gmail.com"
        )
        #expect(
            SpokenSymbolFormatter.format(
                "https dubbele punt slash slash sprekr punt com slash downloads",
                language: .dutch
            ) == "https://sprekr.com/downloads"
        )
        #expect(
            SpokenSymbolFormatter.format(
                "C backslash Users backslash Jibreel",
                language: .automatic
            ) == "C\\Users\\Jibreel"
        )
    }

    @Test
    func spokenSymbolsUseNaturalPunctuationOperatorCurrencyAndSuffixSpacing() {
        #expect(
            SpokenSymbolFormatter.format(
                "Hallo komma wereld dubbele punt dit werkt uitroepteken",
                language: .dutch
            ) == "Hallo, wereld: dit werkt!"
        )
        #expect(
            SpokenSymbolFormatter.format(
                "2 plus 2 is gelijk teken 4",
                language: .dutch
            ) == "2 + 2 = 4"
        )
        #expect(
            SpokenSymbolFormatter.format(
                "20 procentteken en euroteken 20",
                language: .dutch
            ) == "20% en € 20"
        )
        #expect(SpokenSymbolFormatter.format("percentage", language: .dutch) == "%")
    }

    @Test
    func spokenQuotesAndBracketsUseTheirRealTypography() {
        #expect(
            SpokenSymbolFormatter.format(
                "tussen aanhalingstekens Sprekr",
                language: .dutch
            ) == "“Sprekr”"
        )
        #expect(
            SpokenSymbolFormatter.format(
                "open aanhalingstekens heel goed sluit aanhalingstekens",
                language: .dutch
            ) == "“heel goed”"
        )
        #expect(
            SpokenSymbolFormatter.format(
                "open haakje test sluit haakje open vierkante haak waarde sluit vierkante haak open accolade code sluit accolade",
                language: .dutch
            ) == "(test) [waarde] {code}"
        )
        #expect(
            SpokenSymbolFormatter.format(
                "in quotation marks Sprekr",
                language: .english
            ) == "“Sprekr”"
        )
    }

    @Test
    func commonDutchAndEnglishSymbolAliasesAreSupported() {
        let cases: [(String, String, RecognitionLanguage)] = [
            ("at sign", "@", .english),
            ("forward slash", "/", .english),
            ("underscore", "_", .automatic),
            ("ampersand", "&", .automatic),
            ("hekje", "#", .dutch),
            ("sterretje", "*", .dutch),
            ("verticale streep", "|", .dutch),
            ("tilde", "~", .automatic),
            ("caret", "^", .automatic),
            ("backtick", "`", .automatic),
            ("kleiner dan teken", "<", .dutch),
            ("greater than sign", ">", .english),
            ("gradenteken", "°", .dutch),
            ("copyright sign", "©", .english),
            ("registered sign", "®", .english),
            ("handelsmerkteken", "™", .dutch),
            ("dollarteken", "$", .dutch),
            ("British pound sign", "£", .english),
            ("yen sign", "¥", .english),
            ("ápenstaartje", "@", .dutch),
        ]
        for (spoken, expected, language) in cases {
            #expect(SpokenSymbolFormatter.format(spoken, language: language) == expected)
        }
    }

    @Test
    func ambiguousSymbolWordsStayOrdinaryWithoutCommandContext() {
        let unchanged = [
            "Ik maak een punt.",
            "Zie punt 1 van het contract.",
            "Punt 1 gaat over snelheid en Punt 2 over privacy.",
            "Het percentage stijgt vandaag.",
            "Wij hebben een streepje voor.",
            "Kwaliteit plus service blijft belangrijk.",
            "Zes min drie taken blijft gewone taal.",
        ]
        for transcript in unchanged {
            #expect(
                SpokenSymbolFormatter.format(transcript, language: .automatic) == transcript
            )
        }
    }

    @Test
    func explicitSymbolsRemainAvailableWithoutSmartFormattingAndAreIdempotent() {
        let symbolized = SpokenSymbolFormatter.format(
            "mail apenstaartje voorbeeld punt nl vraagteken",
            language: .dutch
        )

        #expect(symbolized == "mail@voorbeeld.nl?")
        #expect(SpokenSymbolFormatter.format(symbolized, language: .dutch) == symbolized)
        #expect(TranscriptFormatter.format(symbolized, language: .dutch) == symbolized)
    }

    @Test
    func spokenEmailRegressionRepairsRealParakeetOutput() {
        let cases: [(String, String)] = [
            ("A puntje Saet abstartje Laif puntnel.", "a.saet@live.nl"),
            ("Jan Peters, @ dmail puntom.", "janpeters@gmail.com"),
            ("Ik ben dom apestaartje live.nl.", "ikbendom@live.nl"),
        ]

        for (transcript, expected) in cases {
            let symbolized = SpokenSymbolFormatter.format(transcript, language: .dutch)
            #expect(SpokenEmailFormatter.format(symbolized, language: .dutch) == expected)
        }
    }

    @Test
    func spokenEmailSupportsCommandsAliasesAndExistingAddresses() {
        let cases: [(String, String, RecognitionLanguage)] = [
            ("john dot doe at sign outlook dot com", "john.doe@outlook.com", .english),
            ("jan apen staartje gmail punt com", "jan@gmail.com", .dutch),
            ("jan at-teken mijnbedrijf punt nl", "jan@mijnbedrijf.nl", .dutch),
            ("jan punt doe plus nieuws underscore test apenstaartje mijn streepje bedrijf punt nl", "jan.doe+nieuws_test@mijn-bedrijf.nl", .dutch),
            ("First.Last+Tag@Custom-Domain.co.uk", "first.last+tag@custom-domain.co.uk", .automatic),
        ]

        for (transcript, expected, language) in cases {
            #expect(SpokenEmailFormatter.format(transcript, language: language) == expected)
        }
    }

    @Test
    func spokenEmailPreservesUnknownDomainsAndEmbeddedPunctuation() {
        #expect(
            SpokenEmailFormatter.format(
                "Mail mij via Jan Peters @ mijnbedrijf punt nl. Bedankt!",
                language: .dutch
            ) == "Mail mij via janpeters@mijnbedrijf.nl. Bedankt!"
        )
        #expect(
            SpokenEmailFormatter.format(
                "Stuur dit naar Jan @ gmail punt com, graag.",
                language: .dutch
            ) == "Stuur dit naar jan@gmail.com, graag."
        )
        #expect(
            SpokenEmailFormatter.format(
                "Mail ik@live.nl. Bedankt!",
                language: .dutch
            ) == "Mail ik@live.nl. Bedankt!"
        )
    }

    @Test
    func spokenEmailLeavesWeakOrInvalidCandidatesAlone() {
        let unchanged = [
            "dmail werkt niet.",
            "laif klinkt vreemd.",
            "puntom is geen commando zonder adres.",
            "Ik ben dom.",
            "Volg @username vandaag.",
            "Volg @username.example vandaag.",
            "a@@gmail.com",
            "jan apenstaartje gmail",
        ]

        for transcript in unchanged {
            #expect(
                SpokenEmailFormatter.format(transcript, language: .automatic) == transcript
            )
        }
    }

    @Test
    func spokenEmailStopsAtSentenceBoundariesAndBoundsTheLocalPart() {
        #expect(
            SpokenEmailFormatter.format(
                "Dit staat los. Jan Peters @ gmail punt com",
                language: .dutch
            ) == "Dit staat los. janpeters@gmail.com"
        )
        #expect(
            SpokenEmailFormatter.format(
                "een twee drie vier vijf zes zeven @ gmail punt com",
                language: .dutch
            ) == "een tweedrieviervijfzeszeven@gmail.com"
        )
    }

    @Test
    func emailLiteralsAreProtectedDuringLocalTranslation() {
        let original = "Mail a.saet@live.nl en janpeters@gmail.com vandaag."
        let protection = SpokenEmailFormatter.protectForTranslation(original)

        #expect(!protection.text.contains("a.saet@live.nl"))
        #expect(!protection.text.contains("janpeters@gmail.com"))
        #expect(protection.restore(in: protection.text) == original)
        #expect(protection.restore(in: protection.text + " gewijzigd") == original + " gewijzigd")
        #expect(protection.restore(in: protection.text.replacingOccurrences(of: "KTEMAIL0", with: "KTMAIL0")) == nil)
    }

    @Test
    func dictionaryCorrectsPersonalEmailSpellingOnceAndKeepsItLowercase() {
        let structured = SpokenEmailFormatter.format(
            "A puntje Saet abstartje Laif puntnel.",
            language: .dutch
        )
        let learned = DictionaryEntry(
            preferredSpelling: "Saed",
            aliases: ["Saet"],
            language: .both
        )

        let corrected = DictionaryCorrectionEngine.apply(
            entries: [learned],
            to: structured,
            language: .dutch
        )

        #expect(structured == "a.saet@live.nl")
        #expect(corrected.text == "a.saed@live.nl")
        #expect(corrected.fixes == 1)
        #expect(corrected.entries.first?.appliedCount == 1)
    }

    @Test
    func dictionaryEmailCorrectionRespectsActivationAndLanguage() {
        let dutchOnly = DictionaryEntry(
            preferredSpelling: "Saed",
            aliases: ["Saet"],
            language: .dutch
        )
        var inactive = dutchOnly
        inactive.isActive = false

        let wrongLanguage = DictionaryCorrectionEngine.apply(
            entries: [dutchOnly],
            to: "a.saet@live.nl",
            language: .english
        )
        let disabled = DictionaryCorrectionEngine.apply(
            entries: [inactive],
            to: "a.saet@live.nl",
            language: .dutch
        )

        #expect(wrongLanguage.text == "a.saet@live.nl")
        #expect(wrongLanguage.fixes == 0)
        #expect(disabled.text == "a.saet@live.nl")
        #expect(disabled.fixes == 0)
    }

    @Test
    func meaningQuestionQuotesTheIntendedPhrase() {
        #expect(
            TranscriptFormatter.format(
                "Wat betekent whatever is whatever you want?",
                language: .automatic
            ) == "Wat betekent “whatever is whatever you want”?"
        )
        #expect(
            TranscriptFormatter.format(
                "Wat betekent het woord autonomie.",
                language: .dutch
            ) == "Wat betekent het woord “autonomie”?"
        )
        #expect(
            TranscriptFormatter.format(
                "What does whatever you want mean?",
                language: .english
            ) == "What does “whatever you want” mean?"
        )
    }

    @Test
    func contextualMeaningQuestionIsNotMisquoted() {
        #expect(
            TranscriptFormatter.format(
                "Wat betekent dit voor onze planning?",
                language: .dutch
            ) == "Wat betekent dit voor onze planning?"
        )
        #expect(
            TranscriptFormatter.format(
                "Wat betekent duurzaamheid voor bedrijven?",
                language: .automatic
            ) == "Wat betekent duurzaamheid voor bedrijven?"
        )
        #expect(
            TranscriptFormatter.format(
                "Wat betekent “autonomie”?",
                language: .dutch
            ) == "Wat betekent “autonomie”?"
        )
    }

    @Test
    func clearDescriptiveLeadInGetsAColon() {
        #expect(
            TranscriptFormatter.format(
                "Ik bedoel het volgende. De microfoon blijft volledig lokaal.",
                language: .dutch
            ) == "Ik bedoel het volgende: De microfoon blijft volledig lokaal."
        )
        #expect(
            TranscriptFormatter.format(
                "Here is what I mean, the transcript stays local.",
                language: .automatic
            ) == "Here is what I mean: the transcript stays local."
        )
        #expect(
            TranscriptFormatter.format(
                "Dit is wat ik bedoel. De transcriptie blijft lokaal.",
                language: .automatic
            ) == "Dit is wat ik bedoel: De transcriptie blijft lokaal."
        )
        #expect(
            TranscriptFormatter.format(
                "Ik weet niet wat het volgende is.",
                language: .dutch
            ) == "Ik weet niet wat het volgende is."
        )
    }

    @Test
    func dutchNumericSelfCorrectionKeepsTheFinalValue() {
        #expect(
            TranscriptFormatter.format(
                "Hallo, ik ben Jip en ik ben 20 en ik ben 18 jaar.",
                language: .dutch
            ) == "Hallo, ik ben Jip en ik ben 18 jaar."
        )
        #expect(
            TranscriptFormatter.format(
                "Hallo, ik ben Jip en ik ben twintig en ik ben achttien jaar.",
                language: .automatic
            ) == "Hallo, ik ben Jip en ik ben 18 jaar."
        )
    }

    @Test
    func englishNumericSelfCorrectionKeepsTheFinalValue() {
        #expect(
            TranscriptFormatter.format(
                "Hello, I am Jip and I am 20 and I am 18 years old.",
                language: .english
            ) == "Hello, I am Jip and I am 18 years old."
        )
    }

    @Test
    func explicitRepairMarkerReplacesOnlyTheMistake() {
        #expect(
            TranscriptFormatter.format(
                "Ik kom dinsdag, nee woensdag.",
                language: .dutch
            ) == "Ik kom woensdag."
        )
        #expect(
            TranscriptFormatter.format(
                "I am twenty years old, sorry, I am eighteen years old.",
                language: .english
            ) == "I am 18 years old."
        )
    }

    @Test
    func immediateRestartIsCollapsed() {
        #expect(
            TranscriptFormatter.format(
                "Ik wil graag ik wil graag een afspraak maken.",
                language: .dutch
            ) == "Ik wil graag een afspraak maken."
        )
    }

    @Test
    func repeatedStutterWordsAndQuestionBoundariesBecomeOneFluentThought() {
        let transcript = "Hoe? Hoe? Hoe doe jij? Jij het volgende. Stel je voor dat ik stotter. Stotter. Kan je dan alsnog de format, format, format goed maken?"

        #expect(
            TranscriptFormatter.format(transcript, language: .dutch)
                == "Hoe doe jij het volgende? Stel je voor dat ik stotter. Kan je dan alsnog de format goed maken?"
        )
    }

    @Test
    func hesitatedAlternativeRestartKeepsOnlyTheFluentRestatement() {
        #expect(
            TranscriptFormatter.format(
                "En ook wat mij opvalt is dat die punctuatie, of en wat mij ook opvalt.",
                language: .dutch
            ) == "En wat mij ook opvalt."
        )
        #expect(
            TranscriptFormatter.format(
                "We can use the first layout, or and we can use the second layout.",
                language: .english
            ) == "And we can use the second layout."
        )
    }

    @Test
    func shortDependentFragmentsUseCommasInsteadOfHardStops() {
        #expect(
            TranscriptFormatter.format(
                "En ook steeds krijg ik een melding van Added. Dat hoef ik niet. Dat hoeft hij niet in twee zinnen te zeggen, toch?",
                language: .dutch
            ) == "En ook steeds krijg ik een melding van Added, dat hoef ik niet, dat hoeft hij niet in 2 zinnen te zeggen, toch?"
        )
        #expect(
            TranscriptFormatter.format(
                "Ik weet dit. Dat werkt vandaag uitstekend.",
                language: .dutch
            ) == "Ik weet dit. Dat werkt vandaag uitstekend."
        )
    }

    @Test
    func partialWordAndShortWordStuttersAreCollapsed() {
        #expect(
            TranscriptFormatter.format(
                "Ik ik wil de for-for-format nog een keer keer controleren.",
                language: .dutch
            ) == "Ik wil de format nog een keer controleren."
        )
        #expect(
            TranscriptFormatter.format(
                "Wa waar? Waarom ben jij zo goed?",
                language: .dutch
            ) == "Waarom ben jij zo goed?"
        )
        #expect(
            TranscriptFormatter.format(
                "Waar? Waarom ben jij zo goed?",
                language: .dutch
            ) == "Waar? Waarom ben jij zo goed?"
        )
    }

    @Test
    func deliberateEmphasisAndGrammaticalDoublesRemainIntact() {
        #expect(
            TranscriptFormatter.format(
                "Dit is heel heel belangrijk.",
                language: .dutch
            ) == "Dit is heel heel belangrijk."
        )
        #expect(
            TranscriptFormatter.format(
                "Ik weet dat dat onderdeel werkt.",
                language: .dutch
            ) == "Ik weet dat dat onderdeel werkt."
        )
        #expect(
            TranscriptFormatter.format(
                "I had had enough by then.",
                language: .english
            ) == "I had had enough by then."
        )
    }

    @Test
    func repeatedNameAcrossNormalSentenceBoundaryIsNotMerged() {
        #expect(
            TranscriptFormatter.format(
                "Ik ken Jip. Jip werkt hier vandaag.",
                language: .dutch
            ) == "Ik ken Jip. Jip werkt hier vandaag."
        )
    }

    @Test
    func intentionalRepeatedFrameIsPreserved() {
        #expect(
            TranscriptFormatter.format(
                "Ik ben Jip en ik ben 18 jaar.",
                language: .dutch
            ) == "Ik ben Jip en ik ben 18 jaar."
        )
        #expect(
            TranscriptFormatter.format(
                "Ik koop appels en ik koop peren.",
                language: .dutch
            ) == "Ik koop appels en ik koop peren."
        )
    }

    @Test
    func dutchEnglishCodeSwitchUsesTheExpectedTweakSpelling() {
        #expect(
            TranscriptFormatter.format(
                "Ik ben de applicatie aan het tweeken en daarna heb ik hem getweekt.",
                language: .automatic
            ) == "Ik ben de applicatie aan het tweaken en daarna heb ik hem getweakt."
        )
    }

    @Test
    func truncatedRepeatedRecognizerTailIsRemoved() {
        let transcript = "Jongens, stop met betalen voor Whisperflow. Ik ben hem even aan het tweeken. Wat extra intelligentie aan het geven. En voordat je het weet zijn we het grootst groeiende bedrijf van heel Arnhem gehad gehad gehad geh"

        #expect(
            TranscriptFormatter.format(transcript, language: .automatic)
                == "Jongens, stop met betalen voor Whisperflow. Ik ben hem even aan het tweaken. Wat extra intelligentie aan het geven. En voordat je het weet zijn we het grootst groeiende bedrijf van heel Arnhem"
        )
    }

    @Test
    func excessiveSingleWordTailIsCollapsedWithoutChangingNaturalEmphasis() {
        #expect(
            TranscriptFormatter.format(
                "De herkenner eindigde met gehad, gehad, gehad.",
                language: .dutch
            ) == "De herkenner eindigde met gehad."
        )
        #expect(
            TranscriptFormatter.format(
                "Dit is echt echt echt belangrijk.",
                language: .dutch
            ) == "Dit is echt echt echt belangrijk."
        )
        #expect(
            TranscriptFormatter.format(
                "Heel heel belangrijk blijft bewuste nadruk.",
                language: .dutch
            ) == "Heel heel belangrijk blijft bewuste nadruk."
        )
    }

    @Test
    func trailingInitialLetterInstructionRewritesTheEarlierWord() {
        #expect(
            TranscriptFormatter.format(
                "Zou je naar Google kunnen gaan en creatives opzoeken? En creatives is met een K.",
                language: .automatic
            ) == "Zou je naar Google kunnen gaan en kreatives opzoeken?"
        )
        #expect(
            TranscriptFormatter.format(
                "Zoek Creatives op. Creatives schrijf je met de letter K.",
                language: .dutch
            ) == "Zoek Kreatives op."
        )
    }

    @Test
    func inlineSpellingInstructionIsRemovedWithoutDroppingTheFollowUp() {
        #expect(
            TranscriptFormatter.format(
                "Zou je voor mij even naar Google kunnen gaan en dan creatives kunnen opzoeken? Creatives is met een K. En zou je dan 20 5 sterren reviews kunnen plaatsen?",
                language: .automatic
            ) == "Zou je voor mij even naar Google kunnen gaan en dan kreatives kunnen opzoeken? En zou je dan 20 5 sterren reviews kunnen plaatsen?"
        )
    }

    @Test
    func trailingDigraphInstructionRewritesTheMatchingVowel() {
        #expect(
            TranscriptFormatter.format(
                "Zou je de website Stilo kunnen opzoeken? En Stilo is met ie.",
                language: .automatic
            ) == "Zou je de website Stielo kunnen opzoeken?"
        )
    }

    @Test
    func spellingInstructionWithoutAnEarlierTargetStaysVisible() {
        #expect(
            TranscriptFormatter.format(
                "De website staat nog niet vast. Stilo is met ie.",
                language: .dutch
            ) == "De website staat nog niet vast. Stilo is met ie."
        )
    }

    @Test
    func staleActivityDoesNotCountAsCurrentStreak() {
        let calendar = Calendar.sprekrAmsterdam
        let old = transcript(on: date(2025, 1, 1, calendar: calendar))
        let summary = InsightsService.summary(
            for: [old],
            calendar: calendar,
            now: date(2025, 1, 5, calendar: calendar)
        )
        #expect(summary.currentStreak == 0)
        #expect(summary.longestStreak == 1)
    }

    @Test
    func amsterdamDSTBoundaryCountsAsConsecutiveDays() {
        let calendar = Calendar.sprekrAmsterdam
        let records = [
            transcript(on: date(2025, 3, 30, calendar: calendar)),
            transcript(on: date(2025, 3, 31, calendar: calendar)),
        ]
        let summary = InsightsService.summary(
            for: records,
            calendar: calendar,
            now: date(2025, 4, 1, calendar: calendar)
        )
        #expect(summary.currentStreak == 2)
        #expect(summary.longestStreak == 2)
    }

    @Test
    @MainActor
    func freshInstallDiskProbeUsesAnExistingVolumeAncestor() {
        #expect((ModelManager.availableDiskSpace() ?? 0) > 0)
    }

    @Test
    func audioMeterSuppressesRoomNoiseButShowsNormalSpeech() {
        #expect(AudioCaptureService.normalizedMeterLevel(forRMS: 0.001) == 0)
        #expect(AudioCaptureService.normalizedMeterLevel(forRMS: 0.01) > 0.35)
        #expect(AudioCaptureService.normalizedMeterLevel(forRMS: 0.10) > 0.75)
        #expect(AudioCaptureService.normalizedMeterLevel(forRMS: 1.0) == 1)
    }

    @Test
    func recordingHasNoElapsedTimeLimitAndIgnoresHealthyConfigurationNotices() {
        #expect(AudioCaptureService.maximumRecordingDuration == nil)
        #expect(!AudioCaptureService.configurationChangeRequiresStopping(
            engineIsRunning: true,
            sampleRate: 48_000,
            channelCount: 1
        ))
        #expect(AudioCaptureService.configurationChangeRequiresStopping(
            engineIsRunning: false,
            sampleRate: 48_000,
            channelCount: 1
        ))
    }

    @Test
    func flowBarUsesDistinctListeningProcessingAndIdleSizes() {
        let idle = FlowBarGeometry.panelSize(for: .idle)
        let hovered = FlowBarGeometry.panelSize(for: .idle, hoverExpanded: true)
        let listening = FlowBarGeometry.panelSize(for: .listening)
        let transcribing = FlowBarGeometry.panelSize(for: .transcribing)

        #expect(idle == NSSize(width: 52, height: 20))
        #expect(hovered == NSSize(width: 114, height: 36))
        #expect(listening == NSSize(width: 86, height: 25))
        #expect(transcribing == NSSize(width: 52, height: 25))
        #expect(transcribing.width >= transcribing.height * 2)
        #expect(transcribing.width <= listening.width)
        #expect(FlowBarGeometry.panelSize(for: .success) == idle)
        #expect(FlowBarGeometry.bottomInset(for: .idle) == 14)
        #expect(FlowBarGeometry.bottomInset(for: .listening) == 18)
    }

    @Test
    func flowBarMessagesFitTheirContentWithinCompactBounds() {
        let deadline = Date(timeIntervalSinceReferenceDate: 10_000)
        let short = FlowBarGeometry.panelSize(
            for: .error(message: "No speech detected", deadline: deadline)
        )
        let recovery = FlowBarGeometry.panelSize(
            for: .recovery(
                message: DictationRecoveryMessage.insertionFailed(reason: .noEditableTarget),
                deadline: deadline
            )
        )

        #expect(FlowBarGeometry.messageHorizontalPadding == 12)
        #expect(FlowBarGeometry.messageWidth(for: "") == FlowBarGeometry.messageMinimumWidth)
        #expect(short.height == FlowBarGeometry.messageHeight)
        #expect(short.width >= FlowBarGeometry.messageMinimumWidth)
        #expect(short.width < 260)
        #expect(recovery.width > short.width)
        #expect(recovery.width <= FlowBarGeometry.messageMaximumWidth)
    }

    @Test
    func flowBarCountdownUsesTheSameDeadlineAsAutoDismissal() {
        let deadline = Date(timeIntervalSinceReferenceDate: 100)
        let duration = FlowBarCountdownPolicy.messageDuration

        let start = FlowBarCountdownPolicy.progress(
            deadline: deadline,
            duration: duration,
            now: deadline.addingTimeInterval(-duration)
        )
        let midpoint = FlowBarCountdownPolicy.progress(
            deadline: deadline,
            duration: duration,
            now: deadline.addingTimeInterval(-duration / 2)
        )
        #expect(abs(start - 1) < 0.000_001)
        #expect(abs(midpoint - 0.5) < 0.000_001)
        #expect(FlowBarCountdownPolicy.progress(
            deadline: deadline,
            duration: duration,
            now: deadline
        ) == 0)
        #expect(FlowBarCountdownPolicy.refreshInterval(reducedMotion: false) == 1.0 / 30.0)
        #expect(FlowBarCountdownPolicy.refreshInterval(reducedMotion: true) == 1)
    }

    @Test
    func staleFlowBarMessageDeadlinesCannotResetANewerState() {
        let first = Date(timeIntervalSinceReferenceDate: 100)
        let second = first.addingTimeInterval(1)
        let current = FlowBarState.error(message: "New message", deadline: second)

        #expect(!FlowBarMessageResetPolicy.shouldReset(
            state: current,
            expectedDeadline: first
        ))
        #expect(FlowBarMessageResetPolicy.shouldReset(
            state: current,
            expectedDeadline: second
        ))
        #expect(!FlowBarMessageResetPolicy.shouldReset(
            state: .listening,
            expectedDeadline: second
        ))
    }

    @Test
    func flowBarSampleUpdatesNeverExposeAShortenedWaveform() {
        let initial = Array(
            repeating: Float.zero,
            count: FlowBarWaveformPolicy.sampleCount
        )
        let quiet = FlowBarSamplePolicy.appending(0, to: initial)
        let resumed = FlowBarSamplePolicy.appending(0.82, to: quiet)

        #expect(quiet.count == FlowBarWaveformPolicy.sampleCount)
        #expect(resumed.count == FlowBarWaveformPolicy.sampleCount)
        #expect(resumed.last == 0.82)
    }

    @Test
    func flowBarWaveformUsesDenseSmoothedRealtimeSamples() {
        let amplitudes = FlowBarWaveformPolicy.smoothedAmplitudes(
            from: [0, 0, 1, 0, 0]
        )

        #expect(FlowBarWaveformPolicy.sampleCount >= 24)
        #expect(FlowBarWaveformPolicy.updateInterval <= .milliseconds(20))
        #expect(amplitudes.count == 5)
        #expect(amplitudes[1] > 0)
        #expect(amplitudes[2] > amplitudes[1])
        #expect(amplitudes[3] == amplitudes[1])
        #expect(amplitudes.allSatisfy { (0...1).contains($0) })
    }

    @Test
    func flowBarHoverExitCollapsesOnlyWhenThePointerIsReallyOutside() {
        let expandedFrame = NSRect(x: 500, y: 14, width: 114, height: 36)

        #expect(!FlowBarHoverPolicy.shouldCollapse(
            panelFrame: expandedFrame,
            pointerLocation: NSPoint(x: 557, y: 32),
            languageMenuPresented: false
        ))
        #expect(FlowBarHoverPolicy.shouldCollapse(
            panelFrame: expandedFrame,
            pointerLocation: NSPoint(x: 620, y: 32),
            languageMenuPresented: false
        ))
        #expect(!FlowBarHoverPolicy.shouldCollapse(
            panelFrame: expandedFrame,
            pointerLocation: NSPoint(x: 620, y: 32),
            languageMenuPresented: true
        ))
        #expect(FlowBarHoverPolicy.collapseDelayMilliseconds > 0)
        #expect(FlowBarHoverPolicy.collapseDuration < FlowBarHoverPolicy.expandDuration)
    }

    @Test
    @MainActor
    func flowBarBlocksNewInputOnlyWhileProcessing() {
        let controller = FlowBarController()

        #expect(controller.acceptsNewDictation)
        #expect(controller.acceptsTap)

        controller.setTranscribing()
        #expect(!controller.acceptsNewDictation)
        #expect(!controller.acceptsTap)

        controller.setSuccess()
        #expect(controller.acceptsNewDictation)
        #expect(controller.acceptsTap)
    }

    @Test
    @MainActor
    func flowBarPanelImmediatelyMatchesEveryStateGeometry() {
        let controller = FlowBarController()

        controller.setListening(level: 0.4)
        #expect(controller.presentedPanelSize == FlowBarGeometry.panelSize(for: .listening))
        #expect(controller.presentedContentSize == controller.presentedPanelSize)

        controller.setTranscribing()
        #expect(controller.presentedPanelSize == FlowBarGeometry.panelSize(for: .transcribing))
        #expect(controller.presentedContentSize == controller.presentedPanelSize)

        controller.setError("No speech detected")
        #expect(controller.presentedPanelSize == FlowBarGeometry.panelSize(for: controller.state))
        #expect(controller.presentedContentSize == controller.presentedPanelSize)

        controller.reset()
        #expect(controller.presentedPanelSize == FlowBarGeometry.panelSize(for: .idle))
        #expect(controller.presentedContentSize == controller.presentedPanelSize)

        controller.setListening(level: 0.4)
        controller.setTranscribing()
        controller.setRecovery(DictationRecoveryMessage.restoredTranscriptCopied)
        #expect(controller.presentedPanelSize == FlowBarGeometry.panelSize(for: controller.state))
        #expect(controller.presentedContentSize == controller.presentedPanelSize)

        controller.reset()
        #expect(controller.presentedPanelSize == FlowBarGeometry.panelSize(for: .idle))
        #expect(controller.presentedContentSize == controller.presentedPanelSize)
    }

    @Test
    @MainActor
    func repeatedFlowBarTransitionsNeverReuseAStaleContentWidth() {
        let controller = FlowBarController()

        for _ in 0..<3 {
            controller.setListening(level: 0.7)
            #expect(controller.presentedPanelSize == NSSize(width: 86, height: 25))
            #expect(controller.presentedContentSize == controller.presentedPanelSize)

            controller.setTranscribing()
            #expect(controller.presentedPanelSize == NSSize(width: 52, height: 25))
            #expect(controller.presentedContentSize == controller.presentedPanelSize)

            controller.reset()
            #expect(controller.presentedPanelSize == NSSize(width: 52, height: 20))
            #expect(controller.presentedContentSize == controller.presentedPanelSize)
        }
    }

    @Test
    @MainActor
    func stateChangeFromExpandedHoverEndsTheHoverTransitionImmediately() async throws {
        let controller = FlowBarController()

        controller.setHoverExpanded(true)
        #expect(controller.isHoverExpanded)

        controller.setListening(level: 0.6)
        #expect(!controller.isHoverExpanded)
        #expect(controller.presentedPanelSize == NSSize(width: 86, height: 25))
        #expect(controller.presentedContentSize == controller.presentedPanelSize)

        try await Task.sleep(for: .milliseconds(250))
        #expect(!controller.isHoverExpanded)
        #expect(controller.presentedPanelSize == NSSize(width: 86, height: 25))
        #expect(controller.presentedContentSize == controller.presentedPanelSize)
    }

    @Test
    func flowBarProcessingStateHasAnIntentionalMinimumPresentation() {
        #expect(FlowBarTransitionPolicy.minimumProcessingPresentation == .milliseconds(700))
        #expect(!FlowBarTransitionPolicy.animatesStateChanges)
        let transcribing = FlowBarGeometry.panelSize(for: .transcribing)
        let listening = FlowBarGeometry.panelSize(for: .listening)
        #expect(transcribing == NSSize(width: 52, height: 25))
        #expect(transcribing.width >= transcribing.height * 2)
        #expect(
            transcribing.width <= listening.width
        )
        #expect(
            FlowBarGeometry.panelSize(for: .success)
                == FlowBarGeometry.panelSize(for: .idle)
        )
    }

    @Test
    func completionCueFollowsVisibleDeliveryWithoutRecoveryNoise() {
        #expect(DictationFeedbackPolicy.completionCueDelay == .milliseconds(70))
        #expect(DictationFeedbackPolicy.startSoundResourceName == "SprekrStart")
        #expect(DictationFeedbackPolicy.startSoundVolume > 0)
        #expect(DictationFeedbackPolicy.startSoundVolume < 0.5)
        #expect(DictationFeedbackPolicy.shouldPlayCompletionCue(copiedForRecovery: false))
        #expect(!DictationFeedbackPolicy.shouldPlayCompletionCue(copiedForRecovery: true))
    }

    @Test
    func successfulTextInsertionRestoresOnlyTheTemporaryClipboardText() {
        #expect(ClipboardRestorationPolicy.restoreDelay < 0.5)
        #expect(ClipboardRestorationPolicy.shouldRestore(
            temporaryText: "dictated text",
            currentText: "dictated text"
        ))
        #expect(!ClipboardRestorationPolicy.shouldRestore(
            temporaryText: "dictated text",
            currentText: "a new copy made by the user"
        ))
        #expect(!ClipboardRestorationPolicy.shouldRestore(
            temporaryText: "dictated text",
            currentText: nil
        ))
    }

    @Test
    func universalEditableTargetPolicyRecognizesNativeWebAndCustomEditors() {
        let nativeTextField = EditableTargetEvidence(role: kAXTextFieldRole as String)
        let safariTextArea = EditableTargetEvidence(
            role: kAXTextAreaRole as String,
            valueSupported: true,
            valueSettable: true
        )
        let electronContentEditable = EditableTargetEvidence(
            role: kAXGroupRole as String,
            reportedEditableAncestor: true
        )
        let browserTextMarkerEditor = EditableTargetEvidence(
            role: kAXTextAreaRole as String,
            selectedTextMarkerRangeSupported: true,
            selectedTextMarkerRangeSettable: true
        )
        let chromiumContentEditableGroup = EditableTargetEvidence(
            role: kAXGroupRole as String,
            selectedTextMarkerRangeSupported: true,
            selectedTextMarkerRangeSettable: true
        )
        let customRangeEditorGroup = EditableTargetEvidence(
            role: kAXGroupRole as String,
            selectedTextRangeSupported: true,
            selectedTextRangeSettable: true
        )
        let customSelectionEditor = EditableTargetEvidence(
            role: kAXGroupRole as String,
            selectedTextSupported: true,
            selectedTextSettable: true
        )

        #expect(EditableTargetPolicy.classify(nativeTextField) == .editable)
        #expect(EditableTargetPolicy.classify(safariTextArea) == .editable)
        #expect(EditableTargetPolicy.classify(electronContentEditable) == .editable)
        #expect(EditableTargetPolicy.classify(browserTextMarkerEditor) == .editable)
        #expect(EditableTargetPolicy.classify(chromiumContentEditableGroup) == .editable)
        #expect(EditableTargetPolicy.classify(customRangeEditorGroup) == .editable)
        #expect(EditableTargetPolicy.classify(customSelectionEditor) == .editable)
    }

    @Test
    func universalEditableTargetPolicyRejectsProtectedReadOnlyAndOrdinaryControls() {
        let secure = EditableTargetEvidence(
            role: kAXTextFieldRole as String,
            subrole: kAXSecureTextFieldSubrole as String,
            selectedTextSupported: true,
            selectedTextSettable: true
        )
        let disabled = EditableTargetEvidence(
            role: kAXTextAreaRole as String,
            enabled: false,
            valueSupported: true,
            valueSettable: true
        )
        let readOnly = EditableTargetEvidence(
            role: kAXTextFieldRole as String,
            selectedTextSupported: true,
            valueSupported: true
        )
        let button = EditableTargetEvidence(role: kAXButtonRole as String)
        let readOnlyWebGroup = EditableTargetEvidence(
            role: kAXGroupRole as String,
            selectedTextMarkerRangeSupported: true
        )
        let valueOnlyWebGroup = EditableTargetEvidence(
            role: kAXGroupRole as String,
            valueSupported: true,
            valueSettable: true
        )
        let secureWebGroup = EditableTargetEvidence(
            role: kAXGroupRole as String,
            subrole: kAXSecureTextFieldSubrole as String,
            selectedTextMarkerRangeSupported: true,
            selectedTextMarkerRangeSettable: true
        )
        let disabledWebGroup = EditableTargetEvidence(
            role: kAXGroupRole as String,
            enabled: false,
            selectedTextRangeSupported: true,
            selectedTextRangeSettable: true
        )
        let writableSlider = EditableTargetEvidence(
            role: kAXSliderRole as String,
            valueSupported: true,
            valueSettable: true
        )
        let selectableWebPage = EditableTargetEvidence(
            role: "AXWebArea",
            selectedTextMarkerRangeSupported: true,
            selectedTextMarkerRangeSettable: true
        )
        let selectableStaticText = EditableTargetEvidence(
            role: kAXStaticTextRole as String,
            selectedTextMarkerRangeSupported: true,
            selectedTextMarkerRangeSettable: true
        )

        #expect(EditableTargetPolicy.classify(secure) == .protectedOrReadOnly)
        #expect(EditableTargetPolicy.classify(disabled) == .protectedOrReadOnly)
        #expect(EditableTargetPolicy.classify(readOnly) == .protectedOrReadOnly)
        #expect(EditableTargetPolicy.classify(button) == .notEditable)
        #expect(EditableTargetPolicy.classify(readOnlyWebGroup) == .notEditable)
        #expect(EditableTargetPolicy.classify(valueOnlyWebGroup) == .notEditable)
        #expect(EditableTargetPolicy.classify(secureWebGroup) == .protectedOrReadOnly)
        #expect(EditableTargetPolicy.classify(disabledWebGroup) == .protectedOrReadOnly)
        #expect(EditableTargetPolicy.classify(writableSlider) == .notEditable)
        #expect(EditableTargetPolicy.classify(selectableWebPage) == .notEditable)
        #expect(EditableTargetPolicy.classify(selectableStaticText) == .notEditable)
    }

    @Test
    func textInjectionResultsKeepActualDeliveryFailureReasons() {
        #expect(TextInjectionResult.clipboardPaste.wasInserted)
        #expect(TextInjectionResult.accessibility.wasInserted)
        #expect(!TextInjectionResult.copiedForRecovery(.noEditableTarget).wasInserted)
        #expect(
            TextInjectionResult.copiedForRecovery(.protectedOrReadOnlyTarget).recoveryReason
                == .protectedOrReadOnlyTarget
        )
        #expect(
            TextInjectionResult.copiedForRecovery(.insertionFailed).recoveryReason
                == .insertionFailed
        )
        #expect(
            TextInjectionResult.copiedForRecovery(.accessibilityTreeUnavailable).recoveryReason
                == .accessibilityTreeUnavailable
        )
    }

    @Test
    func manualAccessibilityActivationUsesUniversalAttributeAndBoundedRetries() {
        #expect(ManualAccessibilityPolicy.attribute == "AXManualAccessibility")
        #expect(ManualAccessibilityPolicy.retryDelaysMilliseconds == [40, 80, 160])
        #expect(
            ManualAccessibilityPolicy.shouldRetryTargetResolution(after: .enabled)
        )
        #expect(
            ManualAccessibilityPolicy.shouldRetryTargetResolution(after: .alreadyEnabled)
        )
        #expect(
            !ManualAccessibilityPolicy.shouldRetryTargetResolution(after: .unsupported)
        )
        #expect(
            !ManualAccessibilityPolicy.shouldRetryTargetResolution(after: .failed)
        )
    }

    @Test
    func deliveryFallbackRetriesOnlyAfterConclusiveUnchangedText() {
        #expect(TextDeliveryFallbackPolicy.shouldRetry(after: .unchanged))
        #expect(!TextDeliveryFallbackPolicy.shouldRetry(after: .changed))
        #expect(!TextDeliveryFallbackPolicy.shouldRetry(after: .indeterminate))
    }

    @Test
    func deliveryVerificationReadsOnlyTheExpectedInsertedSegmentAndCapsItAt64Characters() {
        let short = DeliveryVerificationProbePolicy.probes(
            in: CFRange(location: 12, length: 0),
            expectedText: "Sprekr"
        )
        #expect(short == [DeliveryVerificationProbe(
            location: 12,
            length: 6,
            expectedText: "Sprekr"
        )])

        let longText = String(repeating: "a", count: 40) + String(repeating: "z", count: 40)
        let long = DeliveryVerificationProbePolicy.probes(
            in: CFRange(location: 7, length: 5),
            expectedText: longText
        )
        #expect(long.count == 2)
        #expect(long.reduce(0) { $0 + $1.length } == DeliveryVerificationProbePolicy.maximumCharacterCount)
        #expect(long[0] == DeliveryVerificationProbe(
            location: 7,
            length: 32,
            expectedText: String(repeating: "a", count: 32)
        ))
        #expect(long[1] == DeliveryVerificationProbe(
            location: 55,
            length: 32,
            expectedText: String(repeating: "z", count: 32)
        ))
    }

    @Test
    func flowBarOutputLanguageCyclesWithoutASeparateScratchpadControl() {
        #expect(RecognitionLanguage.automatic.flowBarCode == "AUTO")
        #expect(RecognitionLanguage.dutch.flowBarCode == "NL")
        #expect(RecognitionLanguage.english.flowBarCode == "EN")
        #expect(RecognitionLanguage.automatic.nextOutputLanguage == .dutch)
        #expect(RecognitionLanguage.dutch.nextOutputLanguage == .english)
        #expect(RecognitionLanguage.english.nextOutputLanguage == .automatic)
    }

    @Test
    func projectInfoCopyIsLocalClearAndDashFree() {
        let joined = ProjectInfoCopy.allText.joined(separator: " ")

        #expect(joined.contains("Fiducia Development"))
        #expect(joined.contains("free dictation project"))
        #expect(joined.contains("processed on this Mac"))
        #expect(joined.contains("encrypted local storage"))
        #expect(!joined.contains("-"))
        #expect(!joined.contains("–"))
        #expect(!joined.contains("—"))
    }

    @Test
    func projectInfoCalloutArrowPointsAtTheInfoButtonCenter() {
        #expect(ProjectInfoCalloutGeometry.panelWidth == 410)
        #expect(
            ProjectInfoCalloutGeometry.arrowCenterAboveBottom
                == ProjectInfoCalloutGeometry.infoButtonHeight / 2
        )
    }

    @Test
    func selectedDutchTranslatesEnglishButKeepsDutchSpeech() {
        let englishSpeech = DictationLanguagePlan.make(
            detectedSource: .english,
            outputPreference: .dutch
        )
        let dutchSpeech = DictationLanguagePlan.make(
            detectedSource: .dutch,
            outputPreference: .dutch
        )

        #expect(englishSpeech.requiresTranslation)
        #expect(englishSpeech.outputLanguage == .dutch)
        #expect(!dutchSpeech.requiresTranslation)
        #expect(dutchSpeech.outputLanguage == .dutch)
    }

    @Test
    func selectedEnglishTranslatesDutchWhileAutomaticKeepsTheSource() {
        let englishOutput = DictationLanguagePlan.make(
            detectedSource: .dutch,
            outputPreference: .english
        )
        let automaticOutput = DictationLanguagePlan.make(
            detectedSource: .dutch,
            outputPreference: .automatic
        )

        #expect(englishOutput.requiresTranslation)
        #expect(englishOutput.outputLanguage == .english)
        #expect(!automaticOutput.requiresTranslation)
        #expect(automaticOutput.outputLanguage == .dutch)
    }

    @Test
    func localLanguageDetectorDistinguishesClearDutchAndEnglishSpeech() {
        #expect(SpokenLanguageDetector.detect(in: "Dit is een duidelijke Nederlandse zin over een lokale microfoon.") == .dutch)
        #expect(SpokenLanguageDetector.detect(in: "This is a clear English sentence about a private local microphone.") == .english)
    }

    @Test
    func recoveryMessagesUseSentencesInsteadOfDashSeparators() {
        let messages = [
            DictationRecoveryMessage.historySaveFailed,
            DictationRecoveryMessage.insertionFailed(reason: .insertionFailed),
            DictationRecoveryMessage.insertionFailed(reason: .noEditableTarget),
            DictationRecoveryMessage.insertionFailed(reason: .protectedOrReadOnlyTarget),
            DictationRecoveryMessage.insertionFailed(reason: .accessibilityTreeUnavailable),
            DictationRecoveryMessage.restoredTranscriptCopied,
        ]

        #expect(messages.allSatisfy { !$0.contains("—") })
        #expect(messages[2] == "Copied. Select a text field, then press ⌘V.")
        #expect(messages[3] == "Copied. Select a text field, then press ⌘V.")
        #expect(messages[4] == "Copied. This app hides its text fields from Accessibility.")
        #expect(messages.last == "Your restored text was copied. Press ⌘V to paste.")
    }

    @Test
    func mainWindowStaysWiderThanAHalfScreenTile() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_668, height: 1_073)
        let geometry = MainWindowGeometry.resolve(visibleFrame: visibleFrame)

        #expect(geometry.minimumContentSize.width == 1_167.6)
        #expect(geometry.minimumContentSize.width > visibleFrame.width / 2)
        #expect(
            geometry.minimumContentSize.width
                >= geometry.initialContentSize.width * 0.70
        )
        #expect(geometry.initialContentSize.width <= visibleFrame.width - 32)
    }

    @Test
    func mainWindowGeometryStillFitsACompactDisplay() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_024, height: 700)
        let geometry = MainWindowGeometry.resolve(visibleFrame: visibleFrame)

        #expect(geometry.minimumContentSize.width <= geometry.initialContentSize.width)
        #expect(geometry.initialContentSize.width <= visibleFrame.width - 32)
        #expect(geometry.minimumContentSize.height <= geometry.initialContentSize.height)
        #expect(geometry.initialContentSize.height <= visibleFrame.height - 32)
    }

    @Test
    func historySectionsRollFromTodayToYesterdayAtTheNextLocalDay() {
        let calendar = Calendar.sprekrAmsterdam
        let july14 = transcript(on: date(2026, 7, 14, calendar: calendar))
        let july15 = transcript(on: date(2026, 7, 15, calendar: calendar))

        let onJuly15 = TranscriptDayGrouper.groups(
            for: [july14, july15],
            relativeTo: date(2026, 7, 15, calendar: calendar),
            calendar: calendar
        )
        #expect(onJuly15.map(\.title) == ["Today", "Yesterday"])

        let onJuly16 = TranscriptDayGrouper.groups(
            for: [july14, july15],
            relativeTo: date(2026, 7, 16, calendar: calendar),
            calendar: calendar
        )
        #expect(onJuly16.first?.title == "Yesterday")
        #expect(onJuly16.last?.title == "Tuesday, July 14, 2026")
    }

    @Test
    func streakDayLabelsUseCorrectSingularAndPluralCopy() {
        #expect(InsightsView.dayCountLabel(0) == "0 days")
        #expect(InsightsView.dayCountLabel(1) == "1 day")
        #expect(InsightsView.dayCountLabel(2) == "2 days")
    }

    @Test
    func spokenWordLibraryRetainsOnlyUncommonWordsLocally() {
        let records = [
            TranscriptRecord(
                text: "Vandaag werkt Jibreel aan Sprekr met gewone woorden.",
                createdAt: Date(timeIntervalSince1970: 100),
                audioDuration: 2,
                language: .dutch,
                wasInserted: true,
                dictionaryFixes: 0
            ),
            TranscriptRecord(
                text: "Later test Jibreel dezelfde gewone woorden.",
                createdAt: Date(timeIntervalSince1970: 200),
                audioDuration: 2,
                language: .dutch,
                wasInserted: true,
                dictionaryFixes: 0
            ),
        ]
        let correction = DictionaryEntry(
            preferredSpelling: "Sprekr",
            aliases: ["Sprekr"],
            language: .both
        )
        let known = Set(["vandaag", "werkt", "aan", "met", "gewone", "woorden", "later", "test", "dezelfde"])

        let words = SpokenWordLibrary.build(
            from: records,
            dictionaryEntries: [correction],
            isKnown: { word, _ in known.contains(word.lowercased()) }
        )

        #expect(words.count == 1)
        #expect(words.first?.spelling == "Jibreel")
        #expect(words.first(where: { $0.spelling == "Jibreel" })?.occurrenceCount == 2)
        #expect(!words.contains(where: { $0.spelling == "gewone" }))
        #expect(!words.contains(where: { $0.spelling == "Sprekr" }))
    }

    @Test
    func savedUncommonWordCorrectionAppliesToFutureDictations() {
        let entry = DictionaryEntry(
            preferredSpelling: "Sprekr",
            aliases: ["Spreakr", "Sprekr app"],
            language: .both
        )

        let result = DictionaryCorrectionEngine.apply(
            entries: [entry],
            to: "Open Spreakr en daarna de Sprekr app.",
            language: .dutch
        )

        #expect(result.text == "Open Sprekr en daarna de Sprekr.")
        #expect(result.fixes == 2)
        #expect(result.entries.first?.appliedCount == 2)
    }

    @Test
    func editingAnObservedNameStoresTheHeardFormForFutureDictations() {
        let observation = SpokenWordObservation(
            id: "jibrel",
            spelling: "Jibrel",
            occurrenceCount: 1,
            lastUsedAt: .now,
            language: .dutch,
            isLikelyNameOrBrand: true
        )
        let entry = DictionaryEntryPolicy.preparedEntry(
            original: nil,
            preferredSpelling: "Jibreel",
            suppliedAliases: [],
            observedSpelling: observation.spelling,
            language: DictionaryEntryPolicy.defaultLanguage(for: observation)
        )
        let nextDictation = DictionaryCorrectionEngine.apply(
            entries: [entry],
            to: "Vandaag spreekt Jibrel opnieuw.",
            language: .english
        )

        #expect(entry.aliases == ["Jibrel"])
        #expect(entry.language == .both)
        #expect(nextDictation.text == "Vandaag spreekt Jibreel opnieuw.")
        #expect(nextDictation.fixes == 1)
    }

    @Test
    func dictionaryCanonicalizesCaseDiacriticsAndLongPhrasesInOnePass() {
        let name = DictionaryEntry(
            preferredSpelling: "José",
            aliases: ["Josee"],
            language: .both
        )
        let brand = DictionaryEntry(
            preferredSpelling: "Sprekr",
            aliases: ["Spreakr", "Sprekr app"],
            language: .both
        )
        let result = DictionaryCorrectionEngine.apply(
            entries: [name, brand],
            to: "jose opent de Sprekr app met Josee.",
            language: .dutch
        )

        #expect(result.text == "José opent de Sprekr met José.")
        #expect(result.fixes == 3)
        #expect(result.entries[0].appliedCount == 2)
        #expect(result.entries[1].appliedCount == 1)
    }

    @Test
    func dictionaryUsesOnlyAUniqueSafeFuzzyNameMatch() {
        let learnedName = DictionaryEntry(
            preferredSpelling: "Jibreel",
            aliases: ["Jibrel"],
            language: .both
        )
        let unique = DictionaryCorrectionEngine.apply(
            entries: [learnedName],
            to: "Jibrael is aanwezig.",
            language: .dutch
        )
        #expect(unique.text == "Jibreel is aanwezig.")

        let competingName = DictionaryEntry(
            preferredSpelling: "Jibren",
            aliases: ["Jibren"],
            language: .both
        )
        let ambiguous = DictionaryCorrectionEngine.apply(
            entries: [learnedName, competingName],
            to: "Jibret is aanwezig.",
            language: .dutch
        )
        #expect(ambiguous.text == "Jibret is aanwezig.")
        #expect(ambiguous.fixes == 0)
    }

    @Test
    func dictionaryKeepsOldPreferredSpellingAndDeduplicatesAliases() {
        let original = DictionaryEntry(
            preferredSpelling: "Jibreel",
            aliases: ["Jibrel", "jíbrél"],
            language: .dutch
        )
        let updated = DictionaryEntryPolicy.preparedEntry(
            original: original,
            preferredSpelling: "Djibril",
            suppliedAliases: original.aliases + ["JIBREL"],
            observedSpelling: nil,
            language: .dutch
        )

        #expect(Set(updated.aliases) == Set(["Jibrel", "Jibreel"]))
    }

    @Test
    func dictionaryHonorsLanguageAndActiveState() {
        let inactive = DictionaryEntry(
            preferredSpelling: "Jibreel",
            aliases: ["Jibrel"],
            language: .both,
            isActive: false
        )
        let dutchOnly = DictionaryEntry(
            preferredSpelling: "microfoon",
            aliases: ["microfon"],
            language: .dutch
        )

        let result = DictionaryCorrectionEngine.apply(
            entries: [inactive, dutchOnly],
            to: "Jibrel gebruikt een microfon.",
            language: .english
        )
        #expect(result.text == "Jibrel gebruikt een microfon.")
        #expect(result.fixes == 0)
    }

    private func transcript(on date: Date) -> TranscriptRecord {
        TranscriptRecord(
            text: "one two",
            createdAt: date,
            audioDuration: 1,
            language: .automatic,
            wasInserted: true,
            dictionaryFixes: 0
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        ))!
    }
}
