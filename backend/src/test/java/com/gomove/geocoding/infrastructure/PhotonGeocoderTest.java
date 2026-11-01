package com.gomove.geocoding.infrastructure;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.common.exception.DomainException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.client.ClientHttpResponse;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

import java.io.IOException;
import java.io.InputStream;
import java.net.SocketTimeoutException;
import java.util.Arrays;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withException;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

class PhotonGeocoderTest {
    private MockRestServiceServer server;
    private PhotonGeocoder geocoder;

    @BeforeEach
    void setUp() {
        RestClient.Builder builder = RestClient.builder();
        server = MockRestServiceServer.bindTo(builder).build();
        GeocodingProperties properties = new GeocodingProperties();
        properties.setBaseUrl("https://photon.test/");
        geocoder = new PhotonGeocoder(builder.build(), properties, new ObjectMapper());
    }

    @Test
    void forwardPreservesVietnameseQueryMapsFieldsAndSendsNoCredentials() {
        server.expect(request -> {
            assertThat(request.getURI().getPath()).isEqualTo("/api");
            assertThat(request.getURI().getQuery()).isEqualTo("q=hồ hoàn kiếm&limit=5");
            assertThat(request.getHeaders().containsKey(HttpHeaders.AUTHORIZATION)).isFalse();
            assertThat(request.getHeaders().containsKey(HttpHeaders.COOKIE)).isFalse();
            assertThat(request.getHeaders().getFirst(HttpHeaders.USER_AGENT)).isEqualTo("GoMove-Academic/1.0");
        }).andRespond(withSuccess(collection(feature("105.8524,21.0287",
                "\"name\":\"Hồ Hoàn Kiếm\",\"street\":\"Đinh Tiên Hoàng\","
                        + "\"district\":\"Hoàn Kiếm\",\"city\":\"Hà Nội\"")),
                MediaType.APPLICATION_JSON));

        var places = geocoder.search("hồ hoàn kiếm");
        assertThat(places).hasSize(1);
        assertThat(places.getFirst().label())
                .isEqualTo("Hồ Hoàn Kiếm, Đinh Tiên Hoàng, Hoàn Kiếm, Hà Nội");
        assertThat(places.getFirst().latitude()).isEqualTo(21.0287);
        assertThat(places.getFirst().longitude()).isEqualTo(105.8524);
        assertThat(places.getFirst().attribution()).contains("OpenStreetMap");
        server.verify();
    }

    @Test
    void boundsProviderResultsAndAllowsMissingOptionalAddressFields() {
        StringBuilder features = new StringBuilder();
        for (int i = 0; i < 7; i++) {
            if (i != 0) features.append(',');
            features.append(feature("105.85,21.02", "\"name\":\"Place " + i + "\""));
        }
        server.expect(request -> assertThat(request.getURI().getQuery()).contains("limit=5"))
                .andRespond(withSuccess("{\"features\":[" + features + "]}", MediaType.APPLICATION_JSON));

        var places = geocoder.search("Place");
        assertThat(places).hasSize(5);
        assertThat(places.getFirst().name()).isEqualTo("Place 0");
        assertThat(places.getFirst().street()).isNull();
        assertThat(places.getFirst().district()).isNull();
        assertThat(places.getFirst().city()).isNull();
        server.verify();
    }

    @Test
    void reverseKeepsSelectedPointAndRejectsDistantOrAbsentFeature() {
        server.expect(request -> {
            assertThat(request.getURI().getPath()).isEqualTo("/reverse");
            assertThat(request.getURI().getQuery())
                    .isEqualTo("lat=21.0287&lon=105.8524&limit=1&radius=0.2");
        }).andRespond(withSuccess(collection(feature("105.8525,21.0288",
                "\"street\":\"Đinh Tiên Hoàng\",\"city\":\"Hà Nội\"")),
                MediaType.APPLICATION_JSON));

        var address = geocoder.reverse(21.0287, 105.8524);
        assertThat(address.label()).isEqualTo("Đinh Tiên Hoàng, Hà Nội");
        assertThat(address.latitude()).isEqualTo(21.0287);
        assertThat(address.longitude()).isEqualTo(105.8524);
        server.verify();

        setUp();
        server.expect(request -> {}).andRespond(withSuccess(collection(feature("105.9,21.1",
                "\"name\":\"Distant place\"")), MediaType.APPLICATION_JSON));
        assertThat(geocoder.reverse(21.0287, 105.8524)).isNull();
        server.verify();

        setUp();
        server.expect(request -> {}).andRespond(withSuccess("{\"features\":[]}", MediaType.APPLICATION_JSON));
        assertThat(geocoder.reverse(21.0287, 105.8524)).isNull();
        server.verify();
    }

    @Test
    void malformedGeometryOrOversizedResponseIsGatewayError() {
        String[] invalid = {
                "not-json", "{\"features\":{}}",
                collection(feature("21.0287,105.8524", "\"name\":\"Wrong order\"")),
                collection(feature("181,21.0287", "\"name\":\"Outside earth\"")),
                collection(feature("105.8524,21.0287", "\"street\":123")),
                " ".repeat(128_001)
        };
        for (String body : invalid) {
            setUp();
            server.expect(request -> {}).andRespond(withSuccess(body, MediaType.APPLICATION_JSON));
            assertError(() -> geocoder.search("Place"), HttpStatus.BAD_GATEWAY,
                    "GEOCODING_INVALID_RESPONSE");
            server.verify();
        }
    }

    @Test
    void oversizedStreamingResponseStopsAtTheByteLimit() {
        AtomicInteger bytesRead = new AtomicInteger();
        server.expect(request -> {}).andRespond(request -> new ClientHttpResponse() {
            private final HttpHeaders headers = new HttpHeaders();
            private final InputStream body = new InputStream() {
                @Override
                public int read() throws IOException {
                    if (bytesRead.get() == 128_001) throw new IOException("Unbounded response read");
                    bytesRead.incrementAndGet();
                    return ' ';
                }

                @Override
                public int read(byte[] target, int offset, int length) throws IOException {
                    if (length == 0) return 0;
                    if (bytesRead.get() == 128_001) throw new IOException("Unbounded response read");
                    int amount = Math.min(length, 128_001 - bytesRead.get());
                    Arrays.fill(target, offset, offset + amount, (byte) ' ');
                    bytesRead.addAndGet(amount);
                    return amount;
                }
            };

            @Override public HttpStatus getStatusCode() { return HttpStatus.OK; }
            @Override public String getStatusText() { return "OK"; }
            @Override public HttpHeaders getHeaders() { return headers; }
            @Override public InputStream getBody() { return body; }
            @Override public void close() { }
        });

        assertError(() -> geocoder.search("Place"), HttpStatus.BAD_GATEWAY,
                "GEOCODING_INVALID_RESPONSE");
        assertThat(bytesRead.get()).isEqualTo(128_001);
        server.verify();
    }

    @Test
    void rateLimitServerFailureAndTimeoutReturnStableErrors() {
        server.expect(request -> {}).andRespond(withStatus(HttpStatus.TOO_MANY_REQUESTS));
        assertError(() -> geocoder.search("Place"), HttpStatus.TOO_MANY_REQUESTS,
                "GEOCODING_RATE_LIMITED");
        server.verify();

        setUp();
        server.expect(request -> {}).andRespond(withStatus(HttpStatus.SERVICE_UNAVAILABLE));
        assertError(() -> geocoder.search("Place"), HttpStatus.SERVICE_UNAVAILABLE,
                "GEOCODING_UNAVAILABLE");
        server.verify();

        setUp();
        server.expect(request -> {}).andRespond(withException(new SocketTimeoutException("timeout")));
        assertError(() -> geocoder.search("Place"), HttpStatus.SERVICE_UNAVAILABLE,
                "GEOCODING_UNAVAILABLE");
        server.verify();
    }

    @Test
    void invalidBaseUrlAndTimeoutConfigurationFailFast() {
        GeocodingProperties properties = new GeocodingProperties();
        for (String invalid : new String[] {"ftp://photon.test", "http://user:pass@photon.test",
                "https://photon.test?x=1", "not-a-url"}) {
            properties.setBaseUrl(invalid);
            assertThatThrownBy(() -> new GeocodingConfiguration().photonRestClient(properties))
                    .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("Geocoding base URL");
        }
    }

    private String collection(String feature) {
        return "{\"features\":[" + feature + "]}";
    }

    private String feature(String coordinates, String properties) {
        return "{\"geometry\":{\"type\":\"Point\",\"coordinates\":[" + coordinates + "]},"
                + "\"properties\":{" + properties + "}}";
    }

    private void assertError(Runnable operation, HttpStatus status, String code) {
        assertThatThrownBy(operation::run).isInstanceOf(DomainException.class)
                .satisfies(error -> {
                    DomainException domain = (DomainException) error;
                    assertThat(domain.getStatus()).isEqualTo(status);
                    assertThat(domain.getCode()).isEqualTo(code);
                });
    }
}
