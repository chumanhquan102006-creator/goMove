package com.gomove.location.domain;
import org.springframework.data.jpa.repository.*;
import org.springframework.data.repository.query.Param;
import java.util.*;
public interface FoundationSpatialCheckRepository extends JpaRepository<FoundationSpatialCheck, Long> {
    @Query(value="SELECT * FROM foundation_spatial_check f WHERE ST_DWithin(f.location, CAST(:point AS geography), :meters)", nativeQuery=true)
    List<FoundationSpatialCheck> findWithinMeters(@Param("point") String pointWkt, @Param("meters") double meters);
    @Query(value="SELECT ST_Distance(f.location, CAST(:point AS geography)) FROM foundation_spatial_check f WHERE f.public_id = :publicId", nativeQuery=true)
    Double distanceMeters(@Param("publicId") UUID publicId, @Param("point") String pointWkt);
}
