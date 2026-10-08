package com.gomove.pricing.api;

import com.fasterxml.jackson.annotation.JsonAnySetter;
import com.gomove.vehicle.domain.VehicleType;
import io.swagger.v3.oas.annotations.media.Schema;
import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotNull;

import java.math.BigDecimal;

@Schema(description = "Customer route and vehicle category. Distance and fare are calculated by the server.")
public class CreateQuoteRequest {
    @NotNull @DecimalMin("-90") @DecimalMax("90")
    @Schema(example = "21.0287", requiredMode = Schema.RequiredMode.REQUIRED)
    private BigDecimal pickupLatitude;

    @NotNull @DecimalMin("-180") @DecimalMax("180")
    @Schema(example = "105.8524", requiredMode = Schema.RequiredMode.REQUIRED)
    private BigDecimal pickupLongitude;

    @NotNull @DecimalMin("-90") @DecimalMax("90")
    @Schema(example = "21.0245", requiredMode = Schema.RequiredMode.REQUIRED)
    private BigDecimal dropoffLatitude;

    @NotNull @DecimalMin("-180") @DecimalMax("180")
    @Schema(example = "105.8576", requiredMode = Schema.RequiredMode.REQUIRED)
    private BigDecimal dropoffLongitude;

    @NotNull
    @Schema(example = "MOTORBIKE", requiredMode = Schema.RequiredMode.REQUIRED)
    private VehicleType vehicleType;

    @JsonAnySetter
    void rejectUnexpectedField(String field, Object value) {
        throw new IllegalArgumentException("Unexpected quote request field: " + field);
    }

    public BigDecimal getPickupLatitude() { return pickupLatitude; }
    public void setPickupLatitude(BigDecimal pickupLatitude) { this.pickupLatitude = pickupLatitude; }
    public BigDecimal getPickupLongitude() { return pickupLongitude; }
    public void setPickupLongitude(BigDecimal pickupLongitude) { this.pickupLongitude = pickupLongitude; }
    public BigDecimal getDropoffLatitude() { return dropoffLatitude; }
    public void setDropoffLatitude(BigDecimal dropoffLatitude) { this.dropoffLatitude = dropoffLatitude; }
    public BigDecimal getDropoffLongitude() { return dropoffLongitude; }
    public void setDropoffLongitude(BigDecimal dropoffLongitude) { this.dropoffLongitude = dropoffLongitude; }
    public VehicleType getVehicleType() { return vehicleType; }
    public void setVehicleType(VehicleType vehicleType) { this.vehicleType = vehicleType; }
}
