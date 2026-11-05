import java.net.HttpURLConnection;
import java.net.URI;
import java.nio.charset.StandardCharsets;

/** Tiny JRE-only probe for the container health check and isolated OSRM smoke check. */
public final class HealthProbe {
    private HealthProbe() { }

    public static void main(String[] args) {
        if (args.length != 2) {
            System.exit(2);
        }
        try {
            HttpURLConnection connection = (HttpURLConnection) URI.create(args[0]).toURL().openConnection();
            connection.setConnectTimeout(2000);
            connection.setReadTimeout(2000);
            connection.setRequestMethod("GET");
            if (connection.getResponseCode() != 200) {
                System.exit(1);
            }
            String body = new String(connection.getInputStream().readNBytes(4096), StandardCharsets.UTF_8);
            if (!body.contains(args[1])) {
                System.exit(1);
            }
            connection.disconnect();
        } catch (Exception exception) {
            System.exit(1);
        }
    }
}
