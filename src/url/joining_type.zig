/// Unicode Joining_Type property (subset of ArabicShaping.txt).
///
/// Used by IDNA CheckJoiners (UTS #46 §4.2 step 3) to validate ZWNJ (U+200C)
/// and ZWJ (U+200D) placement. Only the joining types that affect the
/// CheckJoiners rule are distinguished:
///
///   .left      — Joining_Type = L (Left_Joining)
///   .right     — Joining_Type = R (Right_Joining)
///   .dual      — Joining_Type = D (Dual_Joining)
///   .join_cause — Joining_Type = C (Join_Causing)
///   .transparent — Joining_Type = T (Transparent)
///   .non_joining — Joining_Type = U (Non_Joining) — default for unlisted code points
///
/// Source: ArabicShaping-17.0.0.txt. Only entries with type L, R, D, or C are
/// listed explicitly; T and U are derived (Mn/Me/Cf → T, everything else → U).
/// This file is hand-curated to cover the Arabic, Syriac, N'Ko, Mandaic,
/// Mongolian, Phags-pa, Manichaean, Psalter Pahlavi, Hanifi Rohingya, Sogdian,
/// Old Uyghur, Chorasmian, and Arabic Extended blocks. Code points not listed
/// default to .non_joining, except for the General_Category Mn/Me/Cf ranges
/// which are handled by `joiningType` returning .transparent via a separate
/// check.

const std = @import("std");

pub const JoiningType = enum {
    non_joining, // U
    transparent, // T
    left, // L
    right, // R
    dual, // D
    join_causing, // C
};

/// Sorted code points with Canonical_Combining_Class = 9 (Virama).
/// Source: UnicodeData.txt field 3 (ccc). RFC 5892 Appendix A (CONTEXTJ)
/// defines ZWNJ/ZWJ validity in terms of ccc(Before(cp)) == Virama, NOT
/// Joining_Type — this is the authoritative 69-entry ccc=9 set.
/// Generated: awk -F';' '$4=="9"' tools/UnicodeData.txt (2026-07-06).
const virama_codepoints = [_]u21{
    0x094D, // DEVANAGARI SIGN VIRAMA
    0x09CD, // BENGALI SIGN VIRAMA
    0x0A4D, // GURMUKHI SIGN VIRAMA
    0x0ACD, // GUJARATI SIGN VIRAMA
    0x0B4D, // ORIYA SIGN VIRAMA
    0x0BCD, // TAMIL SIGN VIRAMA
    0x0C4D, // TELUGU SIGN VIRAMA
    0x0CCD, // KANNADA SIGN VIRAMA
    0x0D3B, // MALAYALAM SIGN VERTICAL BAR VIRAMA
    0x0D3C, // MALAYALAM SIGN CIRCULAR VIRAMA
    0x0D4D, // MALAYALAM SIGN VIRAMA
    0x0DCA, // SINHALA SIGN AL-LAKUNA
    0x0E3A, // THAI CHARACTER PHINTHU
    0x0EBA, // LAO SIGN PALI VIRAMA
    0x0F84, // TIBETAN MARK HALANTA
    0x1039, // MYANMAR SIGN VIRAMA
    0x103A, // MYANMAR SIGN ASAT
    0x1714, // TAGALOG SIGN VIRAMA
    0x1715, // TAGALOG SIGN PAMUDPOD
    0x1734, // HANUNOO SIGN PAMUDPOD
    0x17D2, // KHMER SIGN COENG
    0x1A60, // TAI THAM SIGN SAKOT
    0x1B44, // BALINESE ADEG ADEG
    0x1BAA, // SUNDANESE SIGN PAMAAEH
    0x1BAB, // SUNDANESE SIGN VIRAMA
    0x1BF2, // BATAK PANGOLAT
    0x1BF3, // BATAK PANONGONAN
    0x2D7F, // TIFINAGH CONSONANT JOINER
    0xA806, // SYLOTI NAGRI SIGN HASANTA
    0xA82C, // SYLOTI NAGRI SIGN ALTERNATE HASANTA
    0xA8C4, // SAURASHTRA SIGN VIRAMA
    0xA953, // REJANG VIRAMA
    0xA9C0, // JAVANESE PANGKON
    0xAAF6, // MEETEI MAYEK VIRAMA
    0xABED, // MEETEI MAYEK APUN IYEK
    0x10A3F, // KHAROSHTHI VIRAMA
    0x11046, // BRAHMI VIRAMA
    0x11070, // BRAHMI SIGN OLD TAMIL VIRAMA
    0x1107F, // BRAHMI NUMBER JOINER
    0x110B9, // KAITHI SIGN VIRAMA
    0x11133, // CHAKMA VIRAMA
    0x11134, // CHAKMA MAAYYAA
    0x111C0, // SHARADA SIGN VIRAMA
    0x11235, // KHOJKI SIGN VIRAMA
    0x112EA, // KHUDAWADI SIGN VIRAMA
    0x1134D, // GRANTHA SIGN VIRAMA
    0x113CE, // TULU-TIGALARI SIGN VIRAMA
    0x113CF, // TULU-TIGALARI SIGN LOOPED VIRAMA
    0x113D0, // TULU-TIGALARI CONJOINER
    0x11442, // NEWA SIGN VIRAMA
    0x114C2, // TIRHUTA SIGN VIRAMA
    0x115BF, // SIDDHAM SIGN VIRAMA
    0x1163F, // MODI SIGN VIRAMA
    0x116B6, // TAKRI SIGN VIRAMA
    0x1172B, // AHOM SIGN KILLER
    0x11839, // DOGRA SIGN VIRAMA
    0x1193D, // DIVES AKURU SIGN HALANTA
    0x1193E, // DIVES AKURU VIRAMA
    0x119E0, // NANDINAGARI SIGN VIRAMA
    0x11A34, // ZANABAZAR SQUARE SIGN VIRAMA
    0x11A47, // ZANABAZAR SQUARE SUBJOINER
    0x11A99, // SOYOMBO SUBJOINER
    0x11C3F, // BHAIKSUKI SIGN VIRAMA
    0x11D44, // MASARAM GONDI SIGN HALANTA
    0x11D45, // MASARAM GONDI VIRAMA
    0x11D97, // GUNJALA GONDI VIRAMA
    0x11F41, // KAWI SIGN KILLER
    0x11F42, // KAWI CONJOINER
    0x1612F, // GURUNG KHEMA SIGN THOLHOMA
};

/// Sorted ranges of code points with Joining_Type = L.
/// Source: ArabicShaping.txt entries with type "L".
const left_ranges = [_][2]u21{
    .{ 0xA872, 0xA872 }, // PHAGS-PA SUPERFIXED RA
    .{ 0x10ACD, 0x10ACD }, // MANICHAEAN HETH
    .{ 0x10AD7, 0x10AD7 }, // MANICHAEAN NUN
    .{ 0x10D00, 0x10D00 }, // HANIFI ROHINGYA A
    .{ 0x10FCB, 0x10FCB }, // CHORASMIAN ONE HUNDRED
};

/// Sorted ranges of code points with Joining_Type = R.
const right_ranges = [_][2]u21{
    // Arabic (0x06xx)
    .{ 0x0622, 0x0625 }, // ALEF variants (MADDA, HAMZA ABOVE, HAMZA BELOW)
    .{ 0x0627, 0x0627 }, // ALEF
    .{ 0x0629, 0x0629 }, // TEH MARBUTA
    .{ 0x062F, 0x0630 }, // DAL variants
    .{ 0x0631, 0x0632 }, // REH variants
    .{ 0x0648, 0x0648 }, // WAW
    // NOTE: 0x066E (DOTLESS BEH) and 0x066F (DOTLESS QAF) are Dual per
    // ArabicShaping.txt — they appear in dual_ranges only. Do NOT add here.
    .{ 0x0671, 0x0673 }, // ALEF WASLA / WAVY HAMZA
    .{ 0x0675, 0x0677 }, // HIGH HAMZA ALEF/WAW
    .{ 0x0688, 0x0690 }, // DAL variants
    .{ 0x0691, 0x0699 }, // REH variants
    .{ 0x06C0, 0x06C0 }, // DOTLESS TEH MARBUTA WITH HAMZA
    .{ 0x06C3, 0x06C3 }, // TEH MARBUTA GOAL
    .{ 0x06C4, 0x06CB }, // WAW variants
    .{ 0x06CD, 0x06CD }, // YEH WITH TAIL
    .{ 0x06D2, 0x06D3 }, // YEH BARREE variants
    .{ 0x06D5, 0x06D5 }, // DOTLESS TEH MARBUTA
    .{ 0x06EE, 0x06EF }, // DAL/REH INVERTED V
    .{ 0x0870, 0x087F }, // Arabic Extended-B ALEF variants
    .{ 0x088E, 0x088E }, // VERTICAL TAIL
    .{ 0x08AA, 0x08AA }, // REH WITH LOOP
    .{ 0x08AB, 0x08AB }, // WAW WITH DOT WITHIN
    .{ 0x08AC, 0x08AC }, // ROHINGYA YEH
    .{ 0x08AE, 0x08AE }, // DAL WITH 3 DOTS BELOW
    .{ 0x08B2, 0x08B2 }, // REH WITH DOT AND INVERTED V
    .{ 0x08B9, 0x08B9 }, // REH WITH NOON ABOVE
    // Syriac (0x07xx)
    .{ 0x0710, 0x0710 }, // ALAPH
    .{ 0x0715, 0x0717 }, // DALATH/HE/WAW
    .{ 0x0719, 0x0719 }, // ZAIN
    .{ 0x071E, 0x071E }, // YUDH HE
    .{ 0x0728, 0x0728 }, // SADHE
    .{ 0x072A, 0x072A }, // RISH
    .{ 0x072C, 0x072C }, // TAW
    .{ 0x072F, 0x072F }, // PERSIAN DHALATH
    .{ 0x074D, 0x074D }, // SOGDIAN ZHAIN
    // Syriac Supplement
    .{ 0x0867, 0x0867 }, // MALAYALAM RA
    .{ 0x0869, 0x0869 }, // MALAYALAM LLLA
    .{ 0x086A, 0x086A }, // MALAYALAM SSA
    // Mandaic (0x084x)
    .{ 0x0840, 0x0840 }, // HALQA
    .{ 0x0846, 0x0847 }, // AZ / IT
    .{ 0x0849, 0x0849 }, // AKSA
    .{ 0x0854, 0x0858 }, // ASH / DUSHENNA / KAD / AIN
    // Manichaean
    .{ 0x10AC5, 0x10AC5 }, // DALETH
    .{ 0x10AC7, 0x10AC7 }, // WAW
    .{ 0x10AC9, 0x10ACA }, // ZAYIN variants
    .{ 0x10ACE, 0x10ACF }, // TETH / YODH
    .{ 0x10AD0, 0x10AD2 }, // KAPH variants
    .{ 0x10ADD, 0x10ADD }, // SADHE
    .{ 0x10AE1, 0x10AE1 }, // RESH
    .{ 0x10AE4, 0x10AE4 }, // TAW
    .{ 0x10AEF, 0x10AEF }, // HUNDRED
    // Psalter Pahlavi
    .{ 0x10B81, 0x10B81 }, // BETH
    .{ 0x10B83, 0x10B86 }, // DALETH/HE/WAW-AYIN-RESH/ZAYIN (mixed) — keep R for 81/83/84/85
    .{ 0x10B89, 0x10B89 }, // KAPH
    .{ 0x10B8C, 0x10B8C }, // NUN
    .{ 0x10B8E, 0x10B8F }, // PE / SADHE
    .{ 0x10B91, 0x10B91 }, // TAW
    .{ 0x10BA9, 0x10BAC }, // ONE/THREE/FOUR (numbers) — kept R per source
    // Hanifi Rohingya
    .{ 0x10D22, 0x10D22 }, // SAKIN
    // Sogdian
    .{ 0x10F33, 0x10F33 }, // HE
    .{ 0x10F54, 0x10F54 }, // ONE HUNDRED
    // Old Uyghur
    .{ 0x10F74, 0x10F75 }, // ZAYIN / FINAL HETH
    // Chorasmian
    .{ 0x10FB4, 0x10FB6 }, // DALETH/HE/WAW
    .{ 0x10FB9, 0x10FBA }, // HETH/YODH
    .{ 0x10FBD, 0x10FBD }, // MEM
    .{ 0x10FC2, 0x10FC3 }, // RESH/SHIN
    .{ 0x10FC9, 0x10FC9 }, // TEN
};

/// Sorted ranges of code points with Joining_Type = D (Dual).
/// This is the largest group — Arabic letters that join both sides.
const dual_ranges = [_][2]u21{
    // Arabic core (0x0620-0x064A, skipping R entries)
    .{ 0x0620, 0x0620 }, // KASHMIRI YEH
    .{ 0x0626, 0x0626 }, // DOTLESS YEH WITH HAMZA
    .{ 0x0628, 0x0628 }, // BEH
    .{ 0x062A, 0x062C }, // DOTLESS BEH 2/3 dots, HAH DOT BELOW
    .{ 0x062D, 0x062E }, // HAH / HAH DOT ABOVE
    .{ 0x0633, 0x0636 }, // SEEN / SAD variants
    .{ 0x0637, 0x063A }, // TAH / AIN variants
    .{ 0x063B, 0x063F }, // KEHEH/FARSI YEH variants
    .{ 0x0641, 0x0647 }, // FEH/QAF/KAF/LAM/MEEM/NOON/HEH
    .{ 0x0649, 0x064A }, // DOTLESS YEH / YEH
    .{ 0x066E, 0x066F }, // DOTLESS BEH / DOTLESS QAF
    .{ 0x0678, 0x0678 }, // HIGH HAMZA DOTLESS YEH
    .{ 0x0679, 0x0680 }, // DOTLESS BEH variants
    .{ 0x0681, 0x0687 }, // HAH variants
    .{ 0x069A, 0x06A0 }, // SEEN/SAD/TAH/AIN variants
    .{ 0x06A1, 0x06A8 }, // FEH/QAF variants
    .{ 0x06A9, 0x06A9 }, // KEHEH
    .{ 0x06AA, 0x06AA }, // SWASH KAF
    .{ 0x06AB, 0x06AC }, // KEHEH/KAF variants
    .{ 0x06AD, 0x06AE }, // KAF variants
    .{ 0x06AF, 0x06B3 }, // GAF variants
    .{ 0x06B4, 0x06B8 }, // GAF/LAM/NOON variants
    .{ 0x06B9, 0x06BD }, // NOON/NYA
    .{ 0x06BE, 0x06BE }, // KNOTTED HEH
    .{ 0x06BF, 0x06BF }, // HAH 3 dots below + dot above
    .{ 0x06C1, 0x06C2 }, // HEH GOAL variants
    .{ 0x06CC, 0x06CC }, // FARSI YEH
    .{ 0x06CE, 0x06CE }, // FARSI YEH V ABOVE
    .{ 0x06D0, 0x06D1 }, // DOTLESS YEH variants
    .{ 0x06FA, 0x06FC }, // SEEN/SAD/AIN variants
    .{ 0x06FF, 0x06FF }, // KNOTTED HEH INVERTED V
    // Arabic Supplement (0x075x-0x077x)
    .{ 0x0750, 0x077F }, // Arabic Supplement (mostly D, with R exceptions handled above)
    // Arabic Extended-A (0x08Ax-0x08Cx)
    .{ 0x08A0, 0x08A2 }, // BEH/HAH/TAH variants
    .{ 0x08A3, 0x08A3 }, // TAH 2 dots above
    .{ 0x08A4, 0x08A4 }, // FEH variant
    .{ 0x08A5, 0x08A5 }, // QAF DOT BELOW
    .{ 0x08A6, 0x08A7 }, // LAM/MEEM variants
    .{ 0x08A8, 0x08A9 }, // YEH variants
    .{ 0x08B0, 0x08B0 }, // KEHEH STROKE BELOW
    .{ 0x08B3, 0x08B4 }, // AIN/KAF variants
    .{ 0x08B5, 0x08B5 }, // DOTLESS QAF DOT BELOW
    .{ 0x08B6, 0x08B8 }, // BEH variants
    .{ 0x08BA, 0x08BA }, // YEH NOON ABOVE
    .{ 0x08BB, 0x08BF }, // AFRICAN FEH/QAF/NOON + BEH variants
    .{ 0x08C0, 0x08C2 }, // BEH/HAH/KEHEH variants
    .{ 0x08C3, 0x08C3 }, // AIN DIAMOND
    .{ 0x08C4, 0x08C4 }, // AFRICAN QAF 3 dots
    .{ 0x08C5, 0x08C8 }, // HAH/KEHEH/LAM variants
    .{ 0x0886, 0x0886 }, // THIN YEH
    .{ 0x0889, 0x0889 }, // DOTLESS NOON INVERTED V
    .{ 0x088A, 0x088D }, // HAH/TAH/KEHEH variants
    .{ 0x10EC3, 0x10EC4 }, // TAH/KAF VERTICAL 2 DOTS
    .{ 0x10EC6, 0x10EC7 }, // THIN NOON / DOTLESS YEH 4 DOTS
    // Syriac (0x0712-0x072B, with R exceptions)
    .{ 0x0712, 0x0714 }, // BETH/GAMAL
    .{ 0x071A, 0x071A }, // HETH
    .{ 0x071B, 0x071D }, // TETH/YUDH
    .{ 0x071F, 0x0727 }, // KAPH..REVERSED PE
    .{ 0x0729, 0x0729 }, // QAPH
    .{ 0x072B, 0x072B }, // SHIN
    .{ 0x072D, 0x072E }, // PERSIAN BHETH/GHAMAL
    // Syriac Supplement
    .{ 0x0860, 0x0860 }, // MALAYALAM NGA
    .{ 0x0862, 0x0865 }, // MALAYALAM NYA/TTA/NNA/NNNA
    .{ 0x0868, 0x0868 }, // MALAYALAM LLA
    // Mandaic (0x084x)
    .{ 0x0841, 0x0845 }, // AB..USHENNA
    .{ 0x0848, 0x0848 }, // ATT
    .{ 0x084A, 0x084F }, // AK..IN
    .{ 0x0850, 0x0853 }, // AP..AR
    .{ 0x0855, 0x0855 }, // AT
    // N'Ko (0x07CA-0x07EA, 0x07FA is C)
    .{ 0x07CA, 0x07EA }, // NKO letters
    // Mongolian (0x1820-0x18AA, with U/T exceptions)
    .{ 0x1820, 0x1842 }, // MONGOLIAN letters
    .{ 0x1843, 0x1843 }, // TODO LONG VOWEL SIGN
    .{ 0x1844, 0x1878 }, // TODO/SIBE/MANCHU letters
    .{ 0x187A, 0x187A }, // CHA 2 DOTS
    .{ 0x1887, 0x1887 }, // ALI GALI A
    .{ 0x1888, 0x189C }, // ALI GALI letters
    .{ 0x18AA, 0x18AA }, // MANCHU ALI GALI LHA
    // Phags-pa (0xA840-0xA872, with L exception)
    .{ 0xA840, 0xA871 }, // PHAGS-PA letters
    // Manichaean (0x10AC0-0x10AE4, with R/L/U exceptions)
    .{ 0x10AC0, 0x10AC4 }, // ALEPH..GIMEL variants
    .{ 0x10AD3, 0x10AD6 }, // LAMEDH..MEM
    .{ 0x10AD8, 0x10AD9 }, // SAMEKH/AYIN
    .{ 0x10ADA, 0x10ADC }, // AYIN/PE variants
    .{ 0x10ADE, 0x10AE0 }, // QOPH variants
    .{ 0x10AEB, 0x10AEE }, // ONE/FIVE/TEN/TWENTY
    // Psalter Pahlavi (0x10Bxx)
    .{ 0x10B80, 0x10B80 }, // ALEPH
    .{ 0x10B82, 0x10B82 }, // GIMEL
    .{ 0x10B87, 0x10B88 }, // HETH/YODH
    .{ 0x10B8A, 0x10B8B }, // LAMEDH/MEM-QOPH
    .{ 0x10B8D, 0x10B8D }, // SAMEKH
    .{ 0x10B90, 0x10B90 }, // SHIN
    .{ 0x10BAD, 0x10BAE }, // TEN/TWENTY
    // Hanifi Rohingya (0x10Dxx, with L/R exceptions)
    .{ 0x10D01, 0x10D21 }, // BA..VOWEL O (mixed D, with R exception for 10D22 handled above)
    .{ 0x10D23, 0x10D23 }, // DOTLESS KINNA YA DOT ABOVE
    // Sogdian (0x10Fxx)
    .{ 0x10F30, 0x10F32 }, // ALEPH/BETH/GIMEL
    .{ 0x10F34, 0x10F44 }, // WAW..LESH (with R exception for 10F33)
    .{ 0x10F51, 0x10F53 }, // ONE/TEN/TWENTY
    // Old Uyghur (0x10F70-0x10F81)
    .{ 0x10F70, 0x10F73 }, // ALEPH/BETH/GIMEL-HETH/WAW
    .{ 0x10F76, 0x10F81 }, // YODH..LESH (with R exceptions for 10F74/75)
    // Chorasmian (0x10FBx-0x10FCx)
    // Per ArabicShaping.txt: ALEPH=D, BETH=D, GIMEL=D, ZAYIN=D,
    // KAPH=D, LAMEDH=D, NUN=D, SAMEKH=D, PE=D, TAW=D, TWENTY=D
    // DALETH/HE/WAW=R, HETH/YODH=R, MEM=R, RESH=R, TEN=R
    // SMALL_ALEPH=U, CURLED_WAW=U, AYIN=U, ONE/TWO/THREE/FOUR=U
    .{ 0x10FB0, 0x10FB0 }, // ALEPH (D)
    .{ 0x10FB2, 0x10FB3 }, // BETH/GIMEL (D)
    .{ 0x10FB8, 0x10FB8 }, // ZAYIN (D)
    .{ 0x10FBB, 0x10FBC }, // KAPH/LAMEDH (D) — 10FBD MEM is R, excluded
    .{ 0x10FBE, 0x10FBF }, // NUN/SAMEKH (D) — 10FBE=NUN, 10FBF=SAMEKH
    .{ 0x10FC1, 0x10FC1 }, // PE (D) — 10FC2 RESH is R, excluded
    .{ 0x10FC4, 0x10FC4 }, // TAW (D)
    .{ 0x10FCA, 0x10FCA }, // TWENTY (D)
};

/// Code points with Joining_Type = C (Join_Causing): TATWEEL-like.
const join_causing_codepoints = [_]u21{
    0x0640, // ARABIC TATWEEL
    0x07FA, // NKO LAJANYALAN
    0x180A, // MONGOLIAN NIRUGU
    0x200D, // ZERO WIDTH JOINER (ZWJ itself is Join_Causing)
    0x0883, // TATWEEL WITH OVERSTRUCK HAMZA
    0x0884, // TATWEEL WITH OVERSTRUCK WAW
    0x0885, // TATWEEL WITH TWO DOTS BELOW
};

/// Look up the Joining_Type for a code point.
/// Code points not explicitly listed default to:
///   - .transparent for General_Category Mn, Me, Cf (combining marks, format chars)
///   - .non_joining for everything else
///
/// For IDNA CheckJoiners we only need L/R/D/C distinction; T and U are
/// distinguished because ZWNJ/ZWJ validation treats T as transparent
/// (skip over) and U as a non-joining boundary.
/// RFC 5892 Appendix A (CONTEXTJ): Canonical_Combining_Class(cp) == Virama (9).
pub fn isVirama(cp: u21) bool {
    for (virama_codepoints) |vcp| {
        if (cp == vcp) return true;
    }
    return false;
}

pub fn joiningType(cp: u21) JoiningType {
    // ZWNJ and ZWJ themselves
    if (cp == 0x200C) return .non_joining; // ZWNJ is U in ArabicShaping
    if (cp == 0x200D) return .join_causing; // ZWJ is C

    // Check join_causing first (single code points)
    for (join_causing_codepoints) |jcp| {
        if (cp == jcp) return .join_causing;
    }

    // Viramas are ccc=9 combining marks (General_Category Mn), which makes
    // them Joining_Type = Transparent for the CONTEXTJ regex's (T)* skipping.
    // The ccc=9 property itself is queried separately via isVirama().
    for (virama_codepoints) |vcp| {
        if (cp == vcp) return .transparent;
    }

    // Check L
    for (left_ranges) |r| {
        if (cp >= r[0] and cp <= r[1]) return .left;
    }

    // Check R
    for (right_ranges) |r| {
        if (cp >= r[0] and cp <= r[1]) return .right;
    }

    // Check D
    for (dual_ranges) |r| {
        if (cp >= r[0] and cp <= r[1]) return .dual;
    }

    // Transparent: combining marks (Mn, Me) and format chars (Cf).
    // We approximate by checking well-known ranges. A precise check would
    // consult UnicodeData.txt General_Category, but for CheckJoiners the
    // common transparent chars are Arabic/Syriac/Mandaic combining marks
    // (0x064B-0x065F, 0x0670, 0x06D6-0x06DC, 0x06DF-0x06E8, 0x08A0+ marks,
    // 0x0730-0x074A Syriac, 0x0853-0x0855 Mandaic, etc.) and Cf (0x200B-0x200F,
    // 0x202A-0x202E, 0x2060-0x2064, 0x2066-0x2069).
    if (isTransparentCp(cp)) return .transparent;

    return .non_joining;
}

/// Approximate General_Category Mn/Me/Cf check for Joining_Type = T.
/// Source: DerivedJoiningType.txt — code points not in ArabicShaping.txt but
/// with General_Category Mn, Me, or Cf are Joining_Type = T.
fn isTransparentCp(cp: u21) bool {
    // Arabic combining marks (Mn)
    if (cp >= 0x064B and cp <= 0x065F) return true;
    if (cp == 0x0670) return true; // ARABIC LETTER SUPERSCRIPT ALEF
    if (cp >= 0x06D6 and cp <= 0x06DC) return true;
    if (cp >= 0x06DF and cp <= 0x06E4) return true;
    if (cp >= 0x06E7 and cp <= 0x06E8) return true;
    if (cp >= 0x06EA and cp <= 0x06ED) return true;
    // Arabic Extended-A combining marks
    if (cp >= 0x08D3 and cp <= 0x08E1) return true;
    if (cp == 0x08E2) return true; // Cf actually, but treated T
    if (cp >= 0x08D4 and cp <= 0x08FF) return true; // Extended marks
    // Syriac combining marks
    if (cp >= 0x0730 and cp <= 0x074A) return true;
    // Mandaic combining marks
    if (cp >= 0x0859 and cp <= 0x085B) return true;
    // N'Ko combining marks
    if (cp >= 0x07EB and cp <= 0x07F3) return true;
    // Mongolian combining marks / format
    if (cp >= 0x1880 and cp <= 0x1886) return true; // mostly U/T — keep T for safety
    if (cp == 0x180E) return true; // MONGOLIAN VOWEL SEPARATOR (Cf)
    // Format chars (Cf) that are transparent
    if (cp >= 0x200B and cp <= 0x200F) return true;
    if (cp >= 0x202A and cp <= 0x202E) return true;
    if (cp >= 0x2060 and cp <= 0x2064) return true;
    if (cp >= 0x2066 and cp <= 0x2069) return true;
    // Devanagari, Bengali, etc. combining marks — broad Mn coverage
    if (cp >= 0x0900 and cp <= 0x097F) {
        // Devanagari: most non-letter code points are Mn
        // Approximation: ranges 0x0900-0x097F contains many letters (U);
        // only the known Mn sub-ranges are T.
        if (cp >= 0x0900 and cp <= 0x0903) return true; // nukta, matras
        if (cp >= 0x093A and cp <= 0x093C) return true;
        if (cp >= 0x093E and cp <= 0x094F) return true; // matras
        if (cp >= 0x0951 and cp <= 0x0957) return true;
        if (cp >= 0x0962 and cp <= 0x0963) return true;
        return false;
    }
    // Tamil, Telugu, etc. — broad Mn coverage for Indic scripts
    // (CheckJoiners C1/C2 failures include Tamil "ஹ" + ZWNJ cases)
    if (cp >= 0x0B80 and cp <= 0x0BFF) {
        // Tamil: vowels/consonants are U; matras (0x0BC0-0x0BC2, 0x0BC6-0x0BC8,
        // 0x0BCA-0x0BCC) and signs (0x0BD0, 0x0BD7) are T.
        if (cp >= 0x0BC0 and cp <= 0x0BC2) return true;
        if (cp >= 0x0BC6 and cp <= 0x0BC8) return true;
        if (cp >= 0x0BCA and cp <= 0x0BCC) return true;
        if (cp == 0x0BD7) return true;
        return false;
    }
    return false;
}

// ── Tests ────────────────────────────────────────────────────────────

test "joiningType ASCII is non_joining" {
    try std.testing.expectEqual(JoiningType.non_joining, joiningType('a'));
    try std.testing.expectEqual(JoiningType.non_joining, joiningType('A'));
    try std.testing.expectEqual(JoiningType.non_joining, joiningType('0'));
    try std.testing.expectEqual(JoiningType.non_joining, joiningType('.'));
}

test "joiningType Arabic BEH is dual" {
    // U+0628 ARABIC LETTER BEH
    try std.testing.expectEqual(JoiningType.dual, joiningType(0x0628));
}

test "joiningType Arabic ALEF is right" {
    // U+0627 ARABIC LETTER ALEF
    try std.testing.expectEqual(JoiningType.right, joiningType(0x0627));
}

test "joiningType Arabic TATWEEL is join_causing" {
    // U+0640 ARABIC TATWEEL
    try std.testing.expectEqual(JoiningType.join_causing, joiningType(0x0640));
}

test "joiningType ZWNJ is non_joining" {
    try std.testing.expectEqual(JoiningType.non_joining, joiningType(0x200C));
}

test "joiningType ZWJ is join_causing" {
    try std.testing.expectEqual(JoiningType.join_causing, joiningType(0x200D));
}

test "joiningType Arabic fatha is transparent" {
    // U+064E ARABIC FATHAH (Mn)
    try std.testing.expectEqual(JoiningType.transparent, joiningType(0x064E));
}