# Notices

Captylo, Copyright (c) 2026 Dawid Kawalec. The source code is licensed under the GNU General Public License v3.0 (see [LICENSE](LICENSE)), except for the parts listed below, which keep their own terms.

## Not covered by the GPL: the Captylo brand

The name "Captylo", the logo, the wordmark, the app and menu bar icons and the other brand artwork are not licensed under the GPL or any other open licence. All rights reserved. This covers `branding/`, the icon sets in `Captylo/Resources/`, `site/assets/brand/`, the favicons and `site/assets/og.jpg`. You may show them to refer to Captylo, but a fork or any other product must use its own name and icons.

The portrait `site/assets/dawid-kawalec.webp` and the "Zmierzch" background video made from our own photo (`Captylo/Resources/Video/`) are not licensed for reuse either.

## Separately licensed code

### Grainient shader (React Bits)

The animated grain gradient is the "Grainient" component from [React Bits](https://github.com/DavidHDev/react-bits), ported to Metal and WebGL2. It is **not** covered by Captylo's GPLv3 and stays under its own licence, "MIT + Commons Clause License Condition v1.0", Copyright (c) 2026 David Haz. That licence allows using it as part of an application, website or product, but not selling, sublicensing or redistributing the component itself, alone, in a bundle or as a ported version.

Files: `Captylo/UI/Glass/Grainient.metal`, the shader in `site/assets/js/grainient.js`, the shader in `docs/design/lab/brand/index.html`.

**Additional permission under GNU GPL version 3 section 7:** If you modify this Program, or any covered work, by linking or combining it with the Grainient shader (or a modified version of it), containing parts covered by the terms of the MIT + Commons Clause License Condition v1.0, the licensors of this Program grant you additional permission to convey the resulting work. Corresponding Source for a non-source form of such a combination shall include the source code for the parts of the Grainient shader used as well as that of the covered work. The shader itself stays under its own licence, so a fork may not sell or redistribute it on its own.

## Third-party components

| Component | Used for | Licence |
|---|---|---|
| [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (argmax-oss-swift) by Argmax, Inc. | on-device speech recognition runtime (Swift package) | MIT |
| [swift-transformers](https://github.com/huggingface/swift-transformers) by Hugging Face, modified by Argmax (`Sources/ArgmaxCore/External` of WhisperKit) | tokenizer and model download code inside WhisperKit | Apache License 2.0 |
| [Whisper large-v3-turbo](https://github.com/openai/whisper) by OpenAI, [Core ML conversion](https://huggingface.co/argmaxinc/whisperkit-coreml) by Argmax | the local speech model, downloaded on first launch (not bundled) | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | meeting voice detection and speaker labels runtime (Swift package) | Apache License 2.0 |
| [Silero VAD](https://github.com/snakers4/silero-vad) by Silero Team, [Core ML conversion](https://huggingface.co/FluidInference/silero-vad-coreml) by FluidInference | detecting speech in meetings, downloaded on first use (not bundled) | MIT |
| [pyannote speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) by pyannote (segmentation, WeSpeaker speaker embedding, PLDA parameters by BUT Speech@FIT), modified [Core ML conversion](https://huggingface.co/FluidInference/speaker-diarization-coreml) by FluidInference | speaker labels in meetings (macOS 15+), downloaded on first use (not bundled) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| [Inter](https://rsms.me/inter/) by Rasmus Andersson | UI typeface, app and site | SIL Open Font License 1.1 (`OFL-Inter.txt`) |
| [Manrope](https://github.com/sharanda/manrope) by Mikhail Sharanda | display typeface, app and site | SIL Open Font License 1.1 (`OFL-Manrope.txt`) |

## Prior work

Captylo is a clean rewrite of VocaType 1, a private fork of [VoiceInk](https://github.com/Beingpax/VoiceInk) by Prakash Joshi Pax (GPLv3). The notes in `docs/reference/port-notes/` describe how that app behaved and quote short parts of its code and prompts for reference; those quotes remain under VoiceInk's GPLv3.

## Other assets

- The photos in `site/assets/stories/` are AI-generated illustrations, labelled as such on the site.
- The sound cues in the app are synthesized for Captylo.
