package com.gomove.pricing.routing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.common.exception.DomainException;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.RouteEstimate;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.http.HttpStatus;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

import java.math.BigDecimal;
import java.net.SocketTimeoutException;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withException;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withServerError;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;
import static org.springframework.http.HttpMethod.GET;

class OsrmRoutingAdapterTest {
    private static final String URL = "http://osrm.test/route/v1/driving/105.8524,21.0287;105.8576,21.0245?overview=false";
    private MockRestServiceServer server;
    private OsrmRoutingAdapter adapter;

    @BeforeEach
    void setUp() {
        RestClient.Builder builder = RestClient.builder();
        server = MockRestServiceServer.bindTo(builder).build();
        OsrmProperties properties = new OsrmProperties();
        properties.setBaseUrl("http://osrm.test/");
        adapter = new OsrmRoutingAdapter(builder.build(), properties, new ObjectMapper());
    }

    @Test
    void parsesRoadDistanceAndDurationWithLongitudeBeforeLatitude() {
        server.expect(requestTo(URL)).andExpect(method(GET))
                .andRespond(withSuccess("{\"code\":\"Ok\",\"routes\":[{\"distance\":754.3,\"duration\":123.5}]}", MediaType.APPLICATION_JSON));

        RouteEstimate route = adapter.calculateRoute(pickup(), dropoff());

        assertThat(route.distanceMeters()).isEqualTo(new BigDecimal("754.300"));
        assertThat(route.durationSeconds()).isEqualTo(new BigDecimal("123.500"));
        assertThat(route.provider()).isEqualTo("OSRM");
        server.verify();
    }

    @Test
    void noRouteOrEmptyRoutesReturnExplicitRouteError() {
        server.expect(requestTo(URL)).andRespond(withSuccess("{\"code\":\"NoRoute\",\"routes\":[]}", MediaType.APPLICATION_JSON));
        assertThatThrownBy(() -> adapter.calculateRoute(pickup(), dropoff()))
                .isInstanceOf(DomainException.class).hasMessageContaining("No road route");
        server.verify();

        setUp();
        server.expect(requestTo(URL)).andRespond(withSuccess("{\"code\":\"Ok\",\"routes\":[]}", MediaType.APPLICATION_JSON));
        assertThatThrownBy(() -> adapter.calculateRoute(pickup(), dropoff()))
                .isInstanceOf(DomainException.class).hasMessageContaining("No road route");
        server.verify();
    }

    @Test
    void httpBadRequestNoRouteReturnsExplicitRouteError() {
        server.expect(requestTo(URL)).andRespond(withStatus(HttpStatus.BAD_REQUEST)
                .body("{\"code\":\"NoRoute\"}").contentType(MediaType.APPLICATION_JSON));

        assertThatThrownBy(() -> adapter.calculateRoute(pickup(), dropoff()))
                .isInstanceOf(DomainException.class).hasMessageContaining("No road route");
        server.verify();
    }

    @Test
    void malformedOrInvalidNumbersReturnGatewayError() {
        server.expect(requestTo(URL)).andRespond(withSuccess("not-json", MediaType.APPLICATION_JSON));
        assertThatThrownBy(() -> adapter.calculateRoute(pickup(), dropoff()))
                .isInstanceOf(DomainException.class).hasMessageContaining("invalid response");
        server.verify();

        setUp();
        server.expect(requestTo(URL)).andRespond(withSuccess("{\"code\":\"Ok\",\"routes\":[{\"distance\":0,\"duration\":20}]}", MediaType.APPLICATION_JSON));
        assertThatThrownBy(() -> adapter.calculateRoute(pickup(), dropoff()))
                .isInstanceOf(DomainException.class).hasMessageContaining("invalid response");
        server.verify();
    }

    @Test
    void httpFailureAndTimeoutReturnUnavailableError() {
        server.expect(requestTo(URL)).andRespond(withServerError());
        assertThatThrownBy(() -> adapter.calculateRoute(pickup(), dropoff()))
                .isInstanceOf(DomainException.class).hasMessageContaining("temporarily unavailable");
        server.verify();

        setUp();
        server.expect(requestTo(URL)).andRespond(withException(new SocketTimeoutException("timeout")));
        assertThatThrownBy(() -> adapter.calculateRoute(pickup(), dropoff()))
                .isInstanceOf(DomainException.class).hasMessageContaining("temporarily unavailable");
        server.verify();
    }

    @Test
    void invalidBaseUrlFailsFastAndDoesNotLeakAnInternalError() {
        OsrmProperties properties = new OsrmProperties();
        properties.setBaseUrl("ftp://osrm.test");
        assertThatThrownBy(() -> new RoutingConfiguration().osrmRestClient(properties))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("OSRM base URL");

        properties.setBaseUrl("http://osrm.test?unexpected=query");
        assertThatThrownBy(() -> new RoutingConfiguration().osrmRestClient(properties))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("OSRM base URL");

        properties.setBaseUrl("not a valid URL");
        assertThatThrownBy(() -> adapterWith(properties).calculateRoute(pickup(), dropoff()))
                .isInstanceOf(DomainException.class).hasMessageContaining("temporarily unavailable");
    }

    private OsrmRoutingAdapter adapterWith(OsrmProperties properties) {
        return new OsrmRoutingAdapter(new RoutingConfiguration().osrmRestClient(new OsrmProperties()),
                properties, new ObjectMapper());
    }

    private GeoCoordinate pickup() {
        return new GeoCoordinate(new BigDecimal("21.0287"), new BigDecimal("105.8524"));
    }

    private GeoCoordinate dropoff() {
        return new GeoCoordinate(new BigDecimal("21.0245"), new BigDecimal("105.8576"));
    }
}
