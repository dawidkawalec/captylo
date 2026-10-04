# Spelling out loud (self-learning spike, CAPTYLO-34)

What the speech engines write when a word is spelled out loud. Input: six Polish phrases read by the macOS voice Zosia (`say -v Zosia -o sN.aiff "..."`), run through `Captylo --transcribe <file> --language pl --engine parakeet|cloud`; `rawText` in the output is the engine text before any processing.

| Spoken | Cloud engine | Parakeet v3 |
|---|---|---|
| Wdrażamy Honcho, pisane H O N C H O, w piątek. | Wdrażamy Honho, pisane HONCHO, w piątek. | Wdrażamy Honho, pisane HONCHO, w piątek. |
| Nazywam się Brzęk, pisane B R Z Ę K. | Nazywam się Brzęk, pisane B-R-Z-Ę-K | Nazywam się brzęk, pisane BRZK. |
| Spotkanie z firmą Captylo, literuję C A P T Y L O. | Spotkanie z firmą Captylo, literuję C-A-P-T-Y-L-O | Spotkanie z firmą Ctylą literuje CAPTY-o. |
| Wrzucam to na Supabase, przez S U P A B A S E. | Wrzucam to na Supabase przez S-U-P-A-B-A-S-E. | Wrzucam to na supabasę, przez SUPABASE. |
| Jego nazwisko to Kawalec, K A W A L E C. | Jego nazwisko to Kawalec, K-A-W-A-L-E-C. | Jego nazwisko to kawalec, kawalece. |
| Dodaj Figmę, pisane ef i gie em a. | Dodaj Figmę pisane F-i-g-m-a | Dodaj figmę, pisane FIGMA. |

(The first cloud row may have fallen back to Parakeet; the cloud passes ran with the user's key.)

Findings, built into `Text/SpellingDetector.swift`:

- The cloud engine writes letters with hyphens (`B-R-Z-Ę-K`), even for Polish letter names. Hyphenated letters count as a spelling with or without a cue word.
- Parakeet merges the letters into one capitalized word after the cue (`pisane HONCHO`) and can drop a Polish letter (`BRZK`). Merged capitals count only after a cue ("pisane", "literuję" / "literuje", "spelled"...), so a plain acronym like "API" is never touched. "przez" is an everyday preposition ("Zapłaciłem przez BLIK"), so it only leads into hyphenated letters; "supabasę, przez SUPABASE" from Parakeet is left as heard.
- A spelling must look like the word before it (the same word, maybe inflected, or at most half the letters different), otherwise nothing is changed ("Wyślij raport, pisane NASA").
- When the spelled word is the heard word (maybe inflected: "figmę" / "FIGMA"), the text keeps the heard word and only the vocabulary learns; a spelling that lost letters ("BRZK") loses to the heard word ("brzęk").
- Without a cue, Parakeet sometimes turns the letters into a word ("kawalece"); nothing can be learned from that.
- Synthetic voice, not a person: repeat with the owner's own recordings before tuning further.
