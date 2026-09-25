package com.music.bitchord.data.lyrics

/**
 * One language the translate button can translate lyrics *into*.
 *
 * [code] is what goes on the wire as the endpoint's `tl` parameter, so it is
 * kept exactly as the endpoint spells it — including the handful that are not
 * bare ISO-639-1: `zh-CN` and `zh-TW` are different scripts of the same
 * language and collapsing either to `zh` silently gives you Simplified, and
 * `mni-Mtei` names the script it is actually written in.
 *
 * [fallbackName] is only reached when the platform has no display name for the
 * code. Where the platform *does* know the language its own name wins, because
 * that one is localised into whatever the app is set to and this one is not.
 */
data class TranslationLanguage(val code: String, val fallbackName: String)

/**
 * Every language the translate endpoint offers, in the order its own picker
 * lists them: alphabetical by English name, which is not the order they end up in
 * once localised, but is the order anyone who has used Translate expects.
 */
val TRANSLATION_LANGUAGES: List<TranslationLanguage> = listOf(
    TranslationLanguage("af", "Afrikaans"),
    TranslationLanguage("sq", "Albanian"),
    TranslationLanguage("am", "Amharic"),
    TranslationLanguage("ar", "Arabic"),
    TranslationLanguage("hy", "Armenian"),
    TranslationLanguage("as", "Assamese"),
    TranslationLanguage("ay", "Aymara"),
    TranslationLanguage("az", "Azerbaijani"),
    TranslationLanguage("bm", "Bambara"),
    TranslationLanguage("eu", "Basque"),
    TranslationLanguage("be", "Belarusian"),
    TranslationLanguage("bn", "Bengali"),
    TranslationLanguage("bho", "Bhojpuri"),
    TranslationLanguage("bs", "Bosnian"),
    TranslationLanguage("bg", "Bulgarian"),
    TranslationLanguage("ca", "Catalan"),
    TranslationLanguage("ceb", "Cebuano"),
    TranslationLanguage("ny", "Chichewa"),
    TranslationLanguage("zh-CN", "Chinese (Simplified)"),
    TranslationLanguage("zh-TW", "Chinese (Traditional)"),
    TranslationLanguage("co", "Corsican"),
    TranslationLanguage("hr", "Croatian"),
    TranslationLanguage("cs", "Czech"),
    TranslationLanguage("da", "Danish"),
    TranslationLanguage("nl", "Dutch"),
    TranslationLanguage("en", "English"),
    TranslationLanguage("eo", "Esperanto"),
    TranslationLanguage("et", "Estonian"),
    TranslationLanguage("fi", "Finnish"),
    TranslationLanguage("fr", "French"),
    TranslationLanguage("fy", "Frisian"),
    TranslationLanguage("gl", "Galician"),
    TranslationLanguage("ka", "Georgian"),
    TranslationLanguage("de", "German"),
    TranslationLanguage("el", "Greek"),
    TranslationLanguage("gu", "Gujarati"),
    TranslationLanguage("ht", "Haitian Creole"),
    TranslationLanguage("ha", "Hausa"),
    TranslationLanguage("haw", "Hawaiian"),
    TranslationLanguage("iw", "Hebrew"),
    TranslationLanguage("hi", "Hindi"),
    TranslationLanguage("hmn", "Hmong"),
    TranslationLanguage("hu", "Hungarian"),
    TranslationLanguage("is", "Icelandic"),
    TranslationLanguage("ig", "Igbo"),
    TranslationLanguage("id", "Indonesian"),
    TranslationLanguage("ga", "Irish"),
    TranslationLanguage("it", "Italian"),
    TranslationLanguage("ja", "Japanese"),
    TranslationLanguage("jw", "Javanese"),
    TranslationLanguage("kn", "Kannada"),
    TranslationLanguage("kk", "Kazakh"),
    TranslationLanguage("km", "Khmer"),
    TranslationLanguage("ko", "Korean"),
    TranslationLanguage("ku", "Kurdish (Kurmanji)"),
    TranslationLanguage("ky", "Kyrgyz"),
    TranslationLanguage("lo", "Lao"),
    TranslationLanguage("la", "Latin"),
    TranslationLanguage("lv", "Latvian"),
    TranslationLanguage("lt", "Lithuanian"),
    TranslationLanguage("lb", "Luxembourgish"),
    TranslationLanguage("mk", "Macedonian"),
    TranslationLanguage("mg", "Malagasy"),
    TranslationLanguage("ms", "Malay"),
    TranslationLanguage("ml", "Malayalam"),
    TranslationLanguage("mt", "Maltese"),
    TranslationLanguage("mi", "Maori"),
    TranslationLanguage("mr", "Marathi"),
    TranslationLanguage("mn", "Mongolian"),
    TranslationLanguage("my", "Myanmar (Burmese)"),
    TranslationLanguage("ne", "Nepali"),
    TranslationLanguage("no", "Norwegian"),
    TranslationLanguage("ps", "Pashto"),
    TranslationLanguage("fa", "Persian"),
    TranslationLanguage("pl", "Polish"),
    TranslationLanguage("pt", "Portuguese"),
    TranslationLanguage("pa", "Punjabi"),
    TranslationLanguage("ro", "Romanian"),
    TranslationLanguage("ru", "Russian"),
    TranslationLanguage("sm", "Samoan"),
    TranslationLanguage("gd", "Scots Gaelic"),
    TranslationLanguage("sr", "Serbian"),
    TranslationLanguage("st", "Sesotho"),
    TranslationLanguage("sn", "Shona"),
    TranslationLanguage("sd", "Sindhi"),
    TranslationLanguage("si", "Sinhala"),
    TranslationLanguage("sk", "Slovak"),
    TranslationLanguage("sl", "Slovenian"),
    TranslationLanguage("so", "Somali"),
    TranslationLanguage("es", "Spanish"),
    TranslationLanguage("su", "Sundanese"),
    TranslationLanguage("sw", "Swahili"),
    TranslationLanguage("sv", "Swedish"),
    TranslationLanguage("tl", "Tagalog"),
    TranslationLanguage("tg", "Tajik"),
    TranslationLanguage("ta", "Tamil"),
    TranslationLanguage("te", "Telugu"),
    TranslationLanguage("th", "Thai"),
    TranslationLanguage("tr", "Turkish"),
    TranslationLanguage("uk", "Ukrainian"),
    TranslationLanguage("ur", "Urdu"),
    TranslationLanguage("ug", "Uyghur"),
    TranslationLanguage("uz", "Uzbek"),
    TranslationLanguage("vi", "Vietnamese"),
    TranslationLanguage("cy", "Welsh"),
    TranslationLanguage("xh", "Xhosa"),
    TranslationLanguage("yi", "Yiddish"),
    TranslationLanguage("yo", "Yoruba"),
    TranslationLanguage("zu", "Zulu"),
)

/**
 * The languages a lyric can be *romanised* from, keyed by what the endpoint wants
 * for `sl` when the romanisation is being asked for directly.
 *
 * Romanisation is only interesting where the source is not already Latin, and
 * for several of these the romanised form and the translated form come from the
 * same machinery — so this is a shortlist of what is worth offering rather than
 * the whole list.
 */
val ROMANIZATION_LANGUAGES: List<TranslationLanguage> = listOf(
    TranslationLanguage("ja", "Japanese"),
    TranslationLanguage("ko", "Korean"),
    TranslationLanguage("zh-CN", "Chinese (Simplified)"),
    TranslationLanguage("zh-TW", "Chinese (Traditional)"),
    TranslationLanguage("ru", "Russian"),
    TranslationLanguage("ar", "Arabic"),
    TranslationLanguage("he", "Hebrew"),
    TranslationLanguage("hi", "Hindi"),
    TranslationLanguage("th", "Thai"),
    TranslationLanguage("el", "Greek"),
    TranslationLanguage("hy", "Armenian"),
    TranslationLanguage("ka", "Georgian"),
    TranslationLanguage("am", "Amharic"),
    TranslationLanguage("bn", "Bengali"),
    TranslationLanguage("ta", "Tamil"),
    TranslationLanguage("te", "Telugu"),
    TranslationLanguage("mr", "Marathi"),
    TranslationLanguage("gu", "Gujarati"),
    TranslationLanguage("kn", "Kannada"),
    TranslationLanguage("ml", "Malayalam"),
    TranslationLanguage("pa", "Punjabi"),
    TranslationLanguage("ur", "Urdu"),
    TranslationLanguage("fa", "Persian"),
    TranslationLanguage("vi", "Vietnamese"),
    TranslationLanguage("km", "Khmer"),
    TranslationLanguage("lo", "Lao"),
    TranslationLanguage("my", "Myanmar (Burmese)"),
    TranslationLanguage("si", "Sinhala"),
    TranslationLanguage("ne", "Nepali"),
)

/**
 * Whether [text] is worth offering to romanise.
 *
 * A cheap all-Latin test, and deliberately only that: the caller has not yet
 * translated, and the question here is whether the *lyric* is in a script that
 * has a romanisation. Detecting which one it is needs a request, which is the
 * thing being avoided.
 */
internal fun isRomanisable(text: String): Boolean =
    text.any { ch -> isNonLatinLetter(ch) }
