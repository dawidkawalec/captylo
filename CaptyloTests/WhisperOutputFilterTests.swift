import Testing
@testable import Captylo

/// Inputs are real Whisper outputs from the owner's meeting (2026-10-02) and its known subtitle credits.
struct WhisperOutputFilterTests {
    @Test func annotationOnlySegmentsArePhantoms() {
        #expect(WhisperOutputFilter.isPhantom(" *szum* *szum*"))
        #expect(WhisperOutputFilter.isPhantom("[MUZYKA]"))
        #expect(WhisperOutputFilter.isPhantom("(śmiech)"))
    }

    @Test func subtitleCreditsArePhantoms() {
        #expect(WhisperOutputFilter.isPhantom("Napisy stworzone przez społeczność Amara.org"))
        #expect(WhisperOutputFilter.isPhantom("Subtitles by the Amara.org community"))
    }

    @Test func realPolishPhrasesStay() {
        #expect(!WhisperOutputFilter.isPhantom("Dziękuję za uwagę."))
        #expect(!WhisperOutputFilter.isPhantom("Do zobaczenia, do usłyszenia."))
        #expect(!WhisperOutputFilter.isPhantom("Mhm."))
    }

    @Test func inlineAnnotationsAreStrippedAndWordsKept() {
        #expect(WhisperOutputFilter.strippingAnnotations("Miłego weekendu. *szum* Do zobaczenia.") == "Miłego weekendu. Do zobaczenia.")
        #expect(WhisperOutputFilter.strippingAnnotations("V1 (klasyczna) zostaje") == "V1 (klasyczna) zostaje")
    }

    @Test func annotationWordsAreRecognised() {
        #expect(WhisperOutputFilter.isAnnotation("*szum*"))
        #expect(WhisperOutputFilter.isAnnotation("[muzyka]."))
        #expect(!WhisperOutputFilter.isAnnotation("szum"))
    }
}
