import java.nio.file.Files;
import java.nio.file.Path;
import java.security.Key;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.Arrays;
import java.util.HexFormat;

/** JDK source launcher: signs exact manifest bytes with an existing app key. */
class SignReleaseManifest {
    private static byte[] readBounded(Path path, long limit) throws Exception {
        long size = Files.size(path);
        if (size <= 0 || size > limit) throw new IllegalArgumentException("Invalid input size");
        byte[] bytes = Files.readAllBytes(path);
        if (bytes.length != size) throw new IllegalArgumentException("Input changed during reading");
        return bytes;
    }

    private static X509Certificate certificate(Path path) throws Exception {
        byte[] bytes = readBounded(path, 128 * 1024);
        try (var input = new java.io.ByteArrayInputStream(bytes)) {
            X509Certificate certificate = (X509Certificate)
                    CertificateFactory.getInstance("X.509").generateCertificate(input);
            if (input.available() != 0 || !Arrays.equals(certificate.getEncoded(), bytes)) {
                throw new IllegalArgumentException("Expected one DER certificate");
            }
            return certificate;
        }
    }

    private static String fingerprint(X509Certificate certificate) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(certificate.getEncoded()));
    }

    private static String algorithm(X509Certificate certificate) {
        return switch (certificate.getPublicKey().getAlgorithm()) {
            case "RSA" -> "SHA256withRSA";
            case "EC" -> "SHA256withECDSA";
            case "DSA" -> "SHA256withDSA";
            default -> throw new IllegalArgumentException("Unsupported application signing key algorithm");
        };
    }

    private static char[] password(String name) {
        String value = System.getenv(name);
        if (value == null || value.isEmpty()) throw new IllegalArgumentException("Missing local signing password");
        return value.toCharArray();
    }

    private static void sign(String[] args) throws Exception {
        if (args.length != 6) throw new IllegalArgumentException("Invalid sign arguments");
        byte[] manifest = readBounded(Path.of(args[1]), 8 * 1024 * 1024);
        X509Certificate expected = certificate(Path.of(args[4]));
        char[] storePassword = password("MITS_RELEASE_STORE_PASSWORD");
        char[] keyPassword = null;
        try {
            keyPassword = password("MITS_RELEASE_KEY_PASSWORD");
            KeyStore store = KeyStore.getInstance(Path.of(args[2]).toFile(), storePassword);
            if (!store.isKeyEntry(args[3])) throw new IllegalArgumentException("Alias is not a private key entry");
            var actual = store.getCertificate(args[3]);
            if (actual == null || !MessageDigest.isEqual(actual.getEncoded(), expected.getEncoded())) {
                throw new IllegalArgumentException("Keystore certificate does not match the APK certificate");
            }
            Key key = store.getKey(args[3], keyPassword);
            if (!(key instanceof PrivateKey)) throw new IllegalArgumentException("Alias has no private key");
            Signature signer = Signature.getInstance(algorithm(expected));
            signer.initSign((PrivateKey) key);
            signer.update(manifest);
            byte[] signature = signer.sign();
            Signature verifier = Signature.getInstance(algorithm(expected));
            verifier.initVerify(expected);
            verifier.update(manifest);
            if (!verifier.verify(signature)) throw new IllegalArgumentException("New signature did not verify");
            Files.write(Path.of(args[5]), signature);
        } finally {
            Arrays.fill(storePassword, '\0');
            if (keyPassword != null) Arrays.fill(keyPassword, '\0');
        }
        System.out.println("Detached build-manifest signature created and verified.");
    }

    private static void verify(String[] args) throws Exception {
        if (args.length != 5) throw new IllegalArgumentException("Invalid verify arguments");
        X509Certificate certificate = certificate(Path.of(args[2]));
        String expected = args[4].replace(":", "").toLowerCase(java.util.Locale.ROOT);
        if (!expected.matches("[0-9a-f]{64}") || !fingerprint(certificate).equals(expected)) {
            throw new IllegalArgumentException("Certificate is not the independently expected signer");
        }
        Signature verifier = Signature.getInstance(algorithm(certificate));
        verifier.initVerify(certificate);
        verifier.update(readBounded(Path.of(args[1]), 8 * 1024 * 1024));
        if (!verifier.verify(readBounded(Path.of(args[3]), 16 * 1024))) {
            throw new IllegalArgumentException("Build-manifest signature did not verify");
        }
        System.out.println("Build-manifest signature verified for certificate SHA-256 " + expected);
    }

    public static void main(String[] args) {
        try {
            if (args.length == 2 && args[0].equals("describe")) {
                X509Certificate certificate = certificate(Path.of(args[1]));
                System.out.println("{\"certificate_sha256\":\"" + fingerprint(certificate)
                        + "\",\"signature_algorithm\":\"" + algorithm(certificate)
                        + "\",\"public_key_algorithm\":\"" + certificate.getPublicKey().getAlgorithm() + "\"}");
            } else if (args.length > 0 && args[0].equals("sign")) {
                sign(args);
            } else if (args.length > 0 && args[0].equals("verify")) {
                verify(args);
            } else {
                throw new IllegalArgumentException("Use describe, sign or verify with the documented paths");
            }
        } catch (Exception failure) {
            // Do not print a stack trace, environment, password, or private-key data.
            System.err.println("Release manifest operation failed. Check the inputs, selected alias, local passwords and independently expected certificate.");
            System.exit(1);
        }
    }
}
