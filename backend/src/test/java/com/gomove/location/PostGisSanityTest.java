package com.gomove.location;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.location.domain.*;
import org.junit.jupiter.api.Test;
import org.locationtech.jts.geom.*;
import org.springframework.beans.factory.annotation.Autowired;
import static org.assertj.core.api.Assertions.assertThat;
class PostGisSanityTest extends BaseIntegrationTest {
    @Autowired FoundationSpatialCheckRepository repository;
    @Test void persistsAndQueriesGeographyInMeters() {
        GeometryFactory factory=new GeometryFactory(new PrecisionModel(),4326);
        Point point=factory.createPoint(new Coordinate(106.7000,10.7000)); point.setSRID(4326);
        FoundationSpatialCheck saved=repository.saveAndFlush(new FoundationSpatialCheck("sanity",point));
        assertThat(saved.getLocation().getSRID()).isEqualTo(4326);
        String second="SRID=4326;POINT(106.7070 10.7000)";
        assertThat(repository.distanceMeters(saved.getPublicId(),second)).isBetween(700d,800d);
        assertThat(repository.findWithinMeters(second,1000)).extracting(FoundationSpatialCheck::getPublicId).contains(saved.getPublicId());
        assertThat(repository.findWithinMeters(second,300)).isEmpty();
    }
}
