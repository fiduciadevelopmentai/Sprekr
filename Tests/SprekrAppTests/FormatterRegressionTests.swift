import Foundation
import Testing
@testable import SprekrApp

/// Regressions for over-eager formatting rules found while auditing the
/// pipeline for Dutch dictation with English terms mixed in.
@Suite("Formatter regressions")
struct FormatterRegressionTests {
    // MARK: - Question inference

    @Test
    func onlyTheQuestionedSentenceGetsAMark() {
        #expect(
            TranscriptFormatter.format("Wat een mooie dag. De zon schijnt.", language: .dutch)
                == "Wat een mooie dag. De zon schijnt."
        )
        #expect(
            TranscriptFormatter.format("Het is klaar. Kunnen we beginnen.", language: .dutch)
                == "Het is klaar. Kunnen we beginnen?"
        )
        #expect(
            TranscriptFormatter.format("Ik heb de code gepusht. Kun je even kijken", language: .dutch)
                == "Ik heb de code gepusht. Kun je even kijken?"
        )
        #expect(
            TranscriptFormatter.format("Wat is dit.\n\nDat is het antwoord.", language: .dutch)
                == "Wat is dit?\n\nDat is het antwoord."
        )
    }

    @Test
    func statementsOpeningWithAQuestionWordStayStatements() {
        for statement in [
            "Wat een mooie dag.",
            "Is goed.",
            "Kan gebeuren.",
            "Hoe dan ook, we gaan door.",
            "Zou kunnen.",
            "Wat mij betreft is dat prima.",
            "Wat ik bedoel is dat het werkt.",
            "Hoe je dat doet maakt niet uit.",
            "Kan ik doen.",
            "Heb ik gedaan.",
            "Moet kunnen.",
            "Wat betreft de planning, we lopen achter.",
        ] {
            #expect(TranscriptFormatter.format(statement, language: .dutch) == statement)
        }
        for statement in ["What a day.", "Whatever you want.", "How you do it is up to you."] {
            #expect(TranscriptFormatter.format(statement, language: .english) == statement)
        }
    }

    @Test
    func invertedQuestionsAreRecognised() {
        let dutch = [
            "Ben je klaar", "Weet jij dat", "Kunnen we starten", "Zullen we gaan", "Ga je mee",
            "Denk je dat", "Vind je dit mooi", "Lukt het vandaag", "Is de microfoon aan", "Heeft Anna gebeld",
            "Mag ik jou iets vragen", "Zijn er nog vragen",
        ]
        for question in dutch {
            #expect(TranscriptFormatter.format(question + ".", language: .dutch) == question + "?")
        }
        let english = ["Have you seen it", "Shall we start", "Don't you think", "Is the build green"]
        for question in english {
            #expect(TranscriptFormatter.format(question + ".", language: .english) == question + "?")
        }
        #expect(
            TranscriptFormatter.format("Hoe laat begint de vergadering.", language: .dutch)
                == "Hoe laat begint de vergadering?"
        )
    }

    @Test
    func questionBeforeSpokenBulletsKeepsItsMark() {
        #expect(
            TranscriptFormatter.format(
                "Wat moeten we doen nieuwe regel bullet point appels bullet point peren",
                language: .automatic
            ) == "Wat moeten we doen?\n\n• appels\n\n• peren"
        )
    }

    @Test
    func decimalsAndHostnamesDoNotSplitAQuestion() {
        #expect(
            TranscriptFormatter.format("Is het 2.5 euro.", language: .dutch) == "Is het 2.5 euro?"
        )
        #expect(
            TranscriptFormatter.format("Kun je github.com openen.", language: .dutch)
                == "Kun je github.com openen?"
        )
    }

    // MARK: - Layout commands

    @Test
    func layoutPhrasesInsideOrdinaryProseAreKept() {
        #expect(
            TranscriptFormatter.format("Zet dit op een nieuwe regel in het bestand.", language: .dutch)
                == "Zet dit op een nieuwe regel in het bestand."
        )
        #expect(
            TranscriptFormatter.format("The bullet points are unclear.", language: .english)
                == "The bullet points are unclear."
        )
        #expect(
            TranscriptFormatter.format("Bullet points are unclear.", language: .automatic)
                == "Bullet points are unclear."
        )
        #expect(
            TranscriptFormatter.format("We launched a new line of products.", language: .english)
                == "We launched a new line of products."
        )
        #expect(
            TranscriptFormatter.format("Eerste zin nieuwe alinea tweede zin", language: .dutch)
                == "Eerste zin\n\ntweede zin"
        )
    }

    // MARK: - Spacing

    @Test
    func spacingKeepsClockTimesSmileysAndSingleTerminals() {
        #expect(
            TranscriptFormatter.format("De trein gaat om 10 : 30.", language: .dutch)
                == "De trein gaat om 10:30."
        )
        #expect(TranscriptFormatter.format("Hoi :)", language: .dutch) == "Hoi :)")
        #expect(
            TranscriptFormatter.format("is dit veilig vraagteken.", language: .automatic)
                == "is dit veilig?"
        )
        #expect(TranscriptFormatter.format("Even wachten...", language: .dutch) == "Even wachten...")
    }

    // MARK: - Repair markers and stutters

    @Test
    func ordinaryUseOfRepairWordsIsKept() {
        for sentence in [
            "Ik zei nee tegen het voorstel.",
            "Ja nee, dat klopt niet.",
            "Ik heb een correctie nodig.",
            "We bouwen een no-code tool.",
            "Nee hoor, dat is prima.",
        ] {
            #expect(TranscriptFormatter.format(sentence, language: .automatic) == sentence)
        }
        for sentence in ["I would rather stay home.", "I'm sorry for the delay.", "There is no way back."] {
            #expect(TranscriptFormatter.format(sentence, language: .english) == sentence)
        }
    }

    @Test
    func hesitatedAndPhrasedRepairsStillApply() {
        #expect(
            TranscriptFormatter.format("Ik kom dinsdag eh nee woensdag.", language: .dutch)
                == "Ik kom woensdag."
        )
        #expect(
            TranscriptFormatter.format("Ik kom dinsdag, ik bedoel eigenlijk woensdag.", language: .dutch)
                == "Ik kom woensdag."
        )
        #expect(
            TranscriptFormatter.format("Ik kom dinsdag, of eigenlijk woensdag.", language: .dutch)
                == "Ik kom woensdag."
        )
        #expect(
            TranscriptFormatter.format("Send it Monday, scratch that, send it Tuesday.", language: .english)
                == "Send it Tuesday."
        )
        #expect(
            TranscriptFormatter.format("Nee, wacht. Ik kom dinsdag, nee woensdag.", language: .dutch)
                == "Nee, wacht. Ik kom woensdag."
        )
    }

    @Test
    func grammaticalDoublesSurviveInDutchDictation() {
        for sentence in [
            "De man die die auto kocht.",
            "De was was droog.",
            "Vul het in in het veld.",
            "Ik weet dat dat werkt.",
            "I had had enough.",
        ] {
            #expect(TranscriptFormatter.format(sentence, language: .dutch) == sentence)
        }
        #expect(
            TranscriptFormatter.format("Ik wil graag ik wil graag een afspraak maken.", language: .dutch)
                == "Ik wil graag een afspraak maken."
        )
    }

    // MARK: - Term lexicon

    @Test
    func lexiconNoLongerRewritesOrdinaryWordsNextToBrands() {
        #expect(TermLexicon.normalize("Staat mijn MacBook er nog?") == "Staat mijn MacBook er nog?")
        #expect(TermLexicon.normalize("I phone him later.") == "I phone him later.")
        #expect(TermLexicon.normalize("We draaien postgrest voor de API.") == "We draaien postgrest voor de API.")
        #expect(TermLexicon.normalize("De copiloot nam over.") == "De copiloot nam over.")
        #expect(TermLexicon.normalize("Een lama in de wei.") == "Een lama in de wei.")
        #expect(TermLexicon.normalize("Ik zoem in op de foto.") == "Ik zoem in op de foto.")
        #expect(TermLexicon.normalize("klaar. github.com is traag.") == "klaar. github.com is traag.")
    }

    @Test
    func phoneticVariantsOfGuardedTermsAreCorrectedWithoutACue() {
        #expect(TermLexicon.normalize("Ik gebruik riakt.") == "Ik gebruik React.")
        #expect(TermLexicon.normalize("Open kursor.") == "Open Cursor.")
        #expect(TermLexicon.normalize("Vraag het aan klode.") == "Vraag het aan Claude.")
        // Real words that double as a brand still need their cue.
        #expect(TermLexicon.normalize("Ik eet een appel.") == "Ik eet een appel.")
        #expect(TermLexicon.normalize("De cursor knippert.") == "De cursor knippert.")
    }

    @Test
    func newTermsAreRecognised() {
        #expect(TermLexicon.normalize("open power shell") == "open PowerShell")
        #expect(TermLexicon.normalize("we gebruiken n acht n en super base") == "we gebruiken n8n en Supabase")
        #expect(TermLexicon.normalize("dat heb ik gefixed en getsjekt") == "dat heb ik gefixt en gecheckt")
        #expect(TermLexicon.normalize("vraag het aan klode code") == "vraag het aan Claude Code")
    }

    @Test
    func lexicalRepairLeavesHashtagsAndIdentifiersAlone() {
        let speller = LexicalRepairFormatter.Speller(
            isKnown: { _, _ in false },
            guesses: { _, _ in ["ingesproken"] }
        )
        #expect(
            LexicalRepairFormatter.repair("#insproken", language: .dutch, speller: speller) == "#insproken"
        )
        #expect(
            LexicalRepairFormatter.repair("user_insproken", language: .dutch, speller: speller)
                == "user_insproken"
        )
        #expect(
            LexicalRepairFormatter.repair("insproken", language: .dutch, speller: speller) == "ingesproken"
        )
    }

    // MARK: - Numbers

    @Test
    func protectedNumberCuesAreWholeWords() {
        #expect(
            SpokenNumberFormatter.format("Please update two settings.", spokenLanguage: .english, outputLanguage: .english)
                == "Please update 2 settings."
        )
        #expect(
            SpokenNumberFormatter.format("De conversie duurt twee minuten.", spokenLanguage: .dutch, outputLanguage: .dutch)
                == "De conversie duurt 2 minuten."
        )
        #expect(
            SpokenNumberFormatter.format("Versie twee is klaar.", spokenLanguage: .dutch, outputLanguage: .dutch)
                == "Versie twee is klaar."
        )
    }

    @Test
    func spokenMinusAfterANumberStaysAWord() {
        #expect(
            SpokenNumberFormatter.format("Zes min drie taken.", spokenLanguage: .dutch, outputLanguage: .dutch)
                == "6 min 3 taken."
        )
        #expect(
            SpokenNumberFormatter.format("min drie graden", spokenLanguage: .dutch, outputLanguage: .dutch)
                == "-3 graden"
        )
    }

    @Test
    func ellipsisCommandSurvivesTheNumberPass() {
        #expect(TranscriptFormatter.format("wacht drie puntjes", language: .dutch) == "wacht…")
        #expect(TranscriptFormatter.format("wait three dots", language: .english) == "wait…")
    }

    @Test
    func articleLikeOnesStayWords() {
        for sentence in ["Nog een dag wachten.", "een jaar geleden", "in één keer", "Zet ze op één lijn."] {
            #expect(
                SpokenNumberFormatter.format(sentence, spokenLanguage: .dutch, outputLanguage: .dutch) == sentence
            )
        }
        for sentence in ["no one came", "a one-off fix", "which one is it", "one day we will"] {
            #expect(
                SpokenNumberFormatter.format(sentence, spokenLanguage: .english, outputLanguage: .english) == sentence
            )
        }
        #expect(
            SpokenNumberFormatter.format("twee euro en een euro", spokenLanguage: .dutch, outputLanguage: .dutch)
                == "2 euro en 1 euro"
        )
    }

    @Test
    func longDigitRunsAndPhoneNumbersAreNotGrouped() {
        #expect(
            SpokenNumberFormatter.format("Bel 31612345678.", spokenLanguage: .dutch, outputLanguage: .dutch)
                == "Bel 31612345678."
        )
        #expect(
            SpokenNumberFormatter.format("Bel 612345.", spokenLanguage: .dutch, outputLanguage: .dutch)
                == "Bel 612345."
        )
        #expect(
            SpokenNumberFormatter.format("Het kost 125000 euro.", spokenLanguage: .dutch, outputLanguage: .dutch)
                == "Het kost 125.000 euro."
        )
    }

    // MARK: - Symbols and e-mail

    @Test
    func punctuationNamesAfterADeterminerStayWords() {
        #expect(TranscriptFormatter.format("Zet daar een komma.", language: .dutch) == "Zet daar een komma.")
        #expect(
            TranscriptFormatter.format("Zet een vraagteken achter de titel.", language: .dutch)
                == "Zet een vraagteken achter de titel."
        )
        #expect(TranscriptFormatter.format("the Oxford comma", language: .english) == "the Oxford comma")
        #expect(TranscriptFormatter.format("is dit veilig vraagteken", language: .dutch) == "is dit veilig?")
        #expect(
            TranscriptFormatter.format("appels komma peren komma bananen", language: .dutch)
                == "appels, peren, bananen"
        )
    }

    @Test
    func spokenHostnamesAndHashtagsGlue() {
        #expect(
            SpokenSymbolFormatter.format("www punt sprekr punt com", language: .dutch) == "www.sprekr.com"
        )
        #expect(
            SpokenSymbolFormatter.format("api punt sprekr punt io", language: .automatic) == "api.sprekr.io"
        )
        #expect(SpokenSymbolFormatter.format("hashtag Sprekr", language: .automatic) == "#Sprekr")
        #expect(
            SpokenSymbolFormatter.format("Dat is het punt nu.", language: .dutch) == "Dat is het punt nu."
        )
    }

    @Test
    func emailProviderFixLeavesRealDomainsAlone() {
        #expect(
            SpokenEmailFormatter.format("jan apenstaartje email punt com", language: .dutch) == "jan@email.com"
        )
        #expect(
            SpokenEmailFormatter.format("jan apenstaartje cloud punt com", language: .dutch) == "jan@cloud.com"
        )
        #expect(
            SpokenEmailFormatter.format("jan apenstaartje life punt nl", language: .dutch) == "jan@life.nl"
        )
        #expect(
            SpokenEmailFormatter.format("jan apenstaartje dmail punt com", language: .dutch) == "jan@gmail.com"
        )
    }

    @Test
    func bareSpokenAtBuildsAnAddressOnlyWithAClearDomain() {
        #expect(TranscriptFormatter.format("jan at gmail punt com", language: .dutch) == "jan@gmail.com")
        #expect(
            TranscriptFormatter.format("mijn e-mail is jan at sprekr punt nl", language: .dutch)
                == "mijn e-mail is jan@sprekr.nl"
        )
        #expect(
            TranscriptFormatter.format("john at outlook dot com", language: .english) == "john@outlook.com"
        )
        #expect(
            TranscriptFormatter.format("Look at sprekr dot com for details.", language: .english)
                == "Look at sprekr.com for details."
        )
        #expect(
            TranscriptFormatter.format("Ik ben at least klaar.", language: .automatic) == "Ik ben at least klaar."
        )
    }

    // MARK: - Discourse structure

    @Test
    func englishOrdinalsInsideNounPhrasesStayProse() {
        let visits = "The first time I visited. The second time was better."
        #expect(TranscriptFormatter.format(visits, language: .english) == visits)
        let attempts = "The very first attempt was slow. My second attempt was better."
        #expect(TranscriptFormatter.format(attempts, language: .english) == attempts)
        #expect(
            TranscriptFormatter.format("First check the logs. Second restart the app.", language: .english)
                == "First check the logs.\n\nSecond restart the app."
        )
    }

    @Test
    func pointReferencesAreNotTurnedIntoSections() {
        let contract = "Zie punt 1 van het contract en punt 2 van de bijlage."
        #expect(TranscriptFormatter.format(contract, language: .dutch) == contract)
        let versions = "We gebruiken versie punt 1 intern en punt 2 in productie."
        #expect(TranscriptFormatter.format(versions, language: .dutch) == versions)
    }

    @Test
    func weakListCueNoLongerBulletsAnOrdinarySentence() {
        let sentence = "Ik heb deze punten al met Anna, Ben en Chris besproken."
        #expect(TranscriptFormatter.format(sentence, language: .dutch) == sentence)
    }

    @Test
    func longFormStructuringKeepsSpokenLineBreaks() {
        let line = Array(repeating: "Dit is een zin die iets vertelt over het werk van vandaag.", count: 5)
            .joined(separator: " ")
        let text = "Eerste regel.\n" + line
        let structured = LongFormParagraphFormatter.structure(text, language: .dutch)
        #expect(structured.hasPrefix("Eerste regel.\n"))
    }

    // MARK: - Dictionary

    @Test
    func dictionaryLeavesIdentifiersAloneAndKeepsSentenceCapitals() {
        let brand = DictionaryEntry(preferredSpelling: "Sprekr", aliases: ["Spreakr"], language: .both)
        let url = DictionaryCorrectionEngine.apply(
            entries: [brand],
            to: "Zie https://spreakr.example.com/docs en #spreakr voor meer.",
            language: .dutch
        )
        #expect(url.text == "Zie https://spreakr.example.com/docs en #spreakr voor meer.")

        let well = DictionaryEntry(preferredSpelling: "Well", aliases: ["well"], language: .both)
        let hyphenated = DictionaryCorrectionEngine.apply(entries: [well], to: "a well-known fix", language: .english)
        #expect(hyphenated.text == "a well-known fix")

        let microphone = DictionaryEntry(preferredSpelling: "microfoon", aliases: ["microfon"], language: .dutch)
        let capitalised = DictionaryCorrectionEngine.apply(
            entries: [microphone],
            to: "Klaar. Microfon werkt. De microfon ook.",
            language: .dutch
        )
        #expect(capitalised.text == "Klaar. Microfoon werkt. De microfoon ook.")
    }

    @Test
    func immediateLearningOnlyAcceptsRespellings() {
        #expect(
            ImmediateCorrectionEngine.detect(original: "De microfoon werkt.", edited: "De camera werkt.") == nil
        )
        #expect(ImmediateCorrectionEngine.detect(original: "zet het daar.", edited: "zet de daar.") == nil)
        #expect(ImmediateCorrectionEngine.detect(original: "open sprekr nu.", edited: "open Sprekr nu.") == nil)
        #expect(
            ImmediateCorrectionEngine.detect(original: "De microfon werkt.", edited: "De microfoon werkt.")
                == ImmediateSpellingCorrection(heard: "microfon", preferred: "microfoon")
        )
    }

    // MARK: - Sentence case

    @Test
    func sentenceCaseSkipsAbbreviationsHostnamesAndInternalCapitals() {
        #expect(
            SentenceCaseFormatter.apply("gebruik bijv. een timeout.") == "gebruik bijv. een timeout."
        )
        #expect(SentenceCaseFormatter.apply("tools o.a. npm en git.") == "tools o.a. npm en git.")
        #expect(SentenceCaseFormatter.apply("zie e.g. the spec.") == "zie e.g. the spec.")
        #expect(SentenceCaseFormatter.apply("dat is i.v.m. de planning.") == "dat is i.v.m. de planning.")
        #expect(SentenceCaseFormatter.apply("klaar. github.com is traag.") == "klaar. github.com is traag.")
        #expect(SentenceCaseFormatter.apply("klaar. sprekr.nl is live.") == "klaar. sprekr.nl is live.")
        #expect(SentenceCaseFormatter.apply("klaar. eBay is traag.") == "klaar. eBay is traag.")
        #expect(
            SentenceCaseFormatter.apply("dit is een zin. en dit ook.") == "dit is een zin. En dit ook."
        )
    }
}
