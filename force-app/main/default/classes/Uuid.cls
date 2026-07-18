/**
 * RFC 4122 version-4 UUID generator.
 *
 * Extracted from ReferralIntakeService, where the inline helper formatted 32 random hex
 * chars with hyphens and called the result a UUID. It never set the version or variant
 * nibbles, so only ~8% of its output was actually RFC 4122 compliant (measured: 3/40).
 * Producer and consumer must agree on the identifier format — a validator requiring real
 * v4 would have rejected ~92% of the ids this org mints, and only in the consuming org,
 * far from the cause. The thing we call a UUID is now actually one.
 *
 * Layout per RFC 4122 §4.4:
 *   - 122 random bits
 *   - version nibble forced to 4
 *   - variant top two bits forced to 10, yielding 8/9/a/b, with the variant's low two
 *     bits left random (replacing the whole nibble with a constant would needlessly
 *     discard two more bits of entropy)
 *
 *   xxxxxxxx-xxxx-4xxx-[89ab]xxx-xxxxxxxxxxxx
 *
 * NOTE ON NAMING: the digit table is HEX_DIGITS and the random payload is randomHex,
 * deliberately not HEX and hex. Apex identifiers are CASE-INSENSITIVE, so a local `hex`
 * silently shadows a constant `HEX` — the constant lookup then indexes into the random
 * string instead. That produced correct version nibbles and random variant nibbles, which
 * is a confusing enough failure that the names are worth keeping distinct.
 */
public with sharing class Uuid {

    private static final String HEX_DIGITS = '0123456789abcdef';

    public static String v4() {
        // 128 cryptographically random bits rendered as 32 lowercase hex chars.
        String randomHex = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).toLowerCase();

        // Variant nibble: keep the low two random bits, force the top two to 10 -> 8|9|a|b.
        Integer variant = (hexValue(randomHex.substring(16, 17)) & 3) | 8;

        return randomHex.substring(0, 8)
            + '-' + randomHex.substring(8, 12)
            + '-4' + randomHex.substring(13, 16)   // version nibble replaced; rest stays random
            + '-' + HEX_DIGITS.substring(variant, variant + 1) + randomHex.substring(17, 20)
            + '-' + randomHex.substring(20, 32);
    }

    private static Integer hexValue(String hexChar) {
        return HEX_DIGITS.indexOf(hexChar);
    }
}
