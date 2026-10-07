package com.gomove.vehicle.service;

import com.gomove.auth.domain.User;
import com.gomove.common.exception.DomainException;
import com.gomove.driver.domain.Driver;
import com.gomove.driver.domain.DriverRepository;
import com.gomove.vehicle.api.CreateVehicleRequest;
import com.gomove.vehicle.domain.Vehicle;
import com.gomove.vehicle.domain.VehicleRepository;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class VehicleServiceTest {
    @Mock
    VehicleRepository vehicles;
    @Mock
    DriverRepository drivers;

    VehicleService service;

    @BeforeEach
    void setUp() {
        service = new VehicleService(vehicles, drivers);
    }

    @Test
    void addVehicleSuccess() {
        Driver driver = driver(5L, UUID.randomUUID());
        when(drivers.findByPublicId(driver.getPublicId())).thenReturn(Optional.of(driver));
        when(vehicles.existsByLicensePlate("79A-222.22")).thenReturn(false);
        when(vehicles.save(any(Vehicle.class))).thenAnswer(invocation -> invocation.getArgument(0));

        Vehicle created = service.addVehicle(driver.getPublicId(),
                new CreateVehicleRequest("79A-222.22", VehicleType.MOTORBIKE, "Honda", "Vision", "Red"));

        assertThat(created.getLicensePlate()).isEqualTo("79A-222.22");
        assertThat(created.getVehicleType()).isEqualTo(VehicleType.MOTORBIKE);
        assertThat(created.isActive()).isFalse();
    }

    @Test
    void setActiveVehicleSwitchesAllToInactiveThenOneActive() {
        Driver driver = driver(6L, UUID.randomUUID());
        Vehicle oldActive = new Vehicle(driver, "79A-333.33", VehicleType.MOTORBIKE, "Yamaha", "Janus", "White");
        oldActive.setActive(true);
        Vehicle target = new Vehicle(driver, "79A-444.44", VehicleType.CAR_4_SEAT, "Kia", "Morning", "Black");
        target.setActive(false);
        UUID targetPublicId = UUID.randomUUID();
        ReflectionTestUtils.setField(target, "publicId", targetPublicId);

        when(drivers.findByPublicId(driver.getPublicId())).thenReturn(Optional.of(driver));
        when(vehicles.findByPublicIdAndDriverId(targetPublicId, 6L)).thenReturn(Optional.of(target), Optional.of(target));

        Vehicle activated = service.setActiveVehicle(driver.getPublicId(), targetPublicId);

        verify(vehicles).deactivateActiveVehiclesByDriverId(6L);
        assertThat(activated.isActive()).isTrue();
    }

    @Test
    void setActiveVehicleThrowsWhenTargetNotFound() {
        Driver driver = driver(7L, UUID.randomUUID());
        UUID missingVehicle = UUID.randomUUID();

        when(drivers.findByPublicId(driver.getPublicId())).thenReturn(Optional.of(driver));
        when(vehicles.findByPublicIdAndDriverId(missingVehicle, 7L)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.setActiveVehicle(driver.getPublicId(), missingVehicle))
                .isInstanceOf(DomainException.class);
    }

    private Driver driver(Long id, UUID publicId) {
        Driver driver = new Driver(new User("0900", null, "bcrypt", "Driver"), "LIC-TEST-" + id);
        ReflectionTestUtils.setField(driver, "id", id);
        ReflectionTestUtils.setField(driver, "publicId", publicId);
        return driver;
    }
}
