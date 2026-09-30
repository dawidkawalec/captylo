# CTC vocabulary boosting in Polish (self-learning stage 6 spike, CAPTYLO-40)

Question: can the learned vocabulary reach the local engine through FluidAudio's CTC keyword boosting (Approach 2: Parakeet TDT 0.6B v3 plus a separate CTC encoder, `SlidingWindowAsrManager.configureVocabularyBoosting`)?

Answer (2026-09-28): **no, not with the current CTC model.** The CTC encoder is the English Parakeet CTC 110M (1024 tokens). On Polish speech it finds vocabulary terms where there are none and replaces real Polish words, which breaks the rule "never remove real Polish words deterministically". Self-learning keeps using replacement rules for non-words and AI hints instead.

## Setup

FluidAudio 0.17.4 CLI (`fluidaudiocli transcribe <wav> --model-version v3 --language pl [--custom-vocab <file>]`), five sentences read by the macOS voice Zosia, 16 kHz mono.

## Results, vocabulary of 8 terms (Honcho, Captylo, Supabase, Vercel, Kawalec, Kubernetes, Brzęczyszczykiewicz, Omnira)

| Spoken | Parakeet alone | With boosting |
|---|---|---|
| Wdrażamy Honcho w piątek na produkcję. | Wdrażamy honho w piątek na produkcję. | Wdrażamy Honcho w piątek na produkcję. |
| Spotkanie z firmą Captylo jest jutro rano. | Spotkanie z firmą Captilo jest jutro rano. | **Kubernetes** Captylo jest jutro rano. |
| Wrzucam wszystko na Supabase i Vercel. | Wrzucam wszystko na supa basę i wercel. | **Kawalec** na Supabase i Vercel |
| Rozmawiałem z Dawidem Kawalcem o Kubernetes. | (correct) | **Omnira** Dawidem Kawalec o Kubernetes. |
| Brzęczyszczykiewicz wysłał raport do Omniry. | (correct) | Brzęczyszczykiewicz raport do Omnira |

The fixes are real (honho, Captilo, supa basę, wercel), but real words are lost ("Spotkanie z firmą", "Wrzucam wszystko", "Rozmawiałem z", "wysłał") and inflection is flattened ("Kawalcem" -> "Kawalec", "Omniry" -> "Omnira").

Stricter settings did not change any output: `--vocab-min-similarity 0.7` / `0.8`, `--vocab-disable-spotter-rescue`, `--vocab-short-term-taper-pivot 5 --vocab-spotter-min-sim 0.6`.

With only two terms (Honcho, Supabase) it still replaced "Rozmawiałem z" and "Brzęczyszczykiewicz wysłał" with "Honcho".

Cost: 0.21 s -> 0.57 s for a short sentence, plus about 100 MB for the CTC encoder.

## Revisit when

FluidAudio ships a multilingual (or Polish) CTC encoder or head; rerun the same five sentences and the two-term check before wiring it in.
