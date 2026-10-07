package com.gomove.vehicle.service;

import com.gomove.auth.domain.*;
import com.gomove.common.exception.DomainException;
import com.gomove.driver.domain.Driver;
import com.gomove.driver.service.DriverService;
import com.gomove.vehicle.api.CreateVehicleRequest;
import com.gomove.vehicle.domain.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.*;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class VehicleServiceTest {
    @Mock VehicleRepository vehicles;
    @Mock DriverService drivers;
    VehicleService service;

    @BeforeEach void setUp() { service = new VehicleService(vehicles, drivers); }

    @Test void driverCanAddOwnVehicle() {
        Driver driver = driver(5L);
        when(drivers.requireDriverProfile(driver.getUser().getPublicId(), UserRole.DRIVER)).thenReturn(driver);
        when(vehicles.existsByLicensePlate("79A-222.22")).thenReturn(false);
        when(vehicles.save(any(Vehicle.class))).thenAnswer(i -> i.getArgument(0));

        Vehicle created = service.addVehicleForCurrentDriver(driver.getUser().getPublicId(), UserRole.DRIVER,
                new CreateVehicleRequest("79A-222.22", VehicleType.MOTORBIKE, "Honda", "Vision", "Red"));

        assertThat(created.getDriver()).isSameAs(driver);
    }

    @Test void activationIsScopedToCurrentDriver() {
        Driver driver = driver(6L);
        UUID vehiclePublicId = UUID.randomUUID();
        Vehicle target = new Vehicle(driver, "79A-444.44", VehicleType.CAR_4_SEAT, "Kia", "Morning", "Black");
        ReflectionTestUtils.setField(target, "publicId", vehiclePublicId);
        when(drivers.requireDriverProfile(driver.getUser().getPublicId(), UserRole.DRIVER)).thenReturn(driver);
        when(vehicles.findByPublicIdAndDriverId(vehiclePublicId, 6L)).thenAnswer(invocation -> Optional.of(target));

        Vehicle activated = service.setActiveVehicleForCurrentDriver(driver.getUser().getPublicId(), UserRole.DRIVER, vehiclePublicId);

        verify(vehicles).deactivateActiveVehiclesByDriverId(6L);
        assertThat(activated.isActive()).isTrue();
    }

    @Test void otherDriversVehicleCannotBeActivated() {
        Driver driver = driver(7L);
        when(drivers.requireDriverProfile(driver.getUser().getPublicId(), UserRole.DRIVER)).thenReturn(driver);
        when(vehicles.findByPublicIdAndDriverId(any(), eq(7L))).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.setActiveVehicleForCurrentDriver(driver.getUser().getPublicId(), UserRole.DRIVER, UUID.randomUUID()))
                .isInstanceOf(DomainException.class);
        verify(vehicles, never()).deactivateActiveVehiclesByDriverId(anyLong());
    }

    private Driver driver(Long id) {
        User user = new User("0900" + id, null, "bcrypt", "Driver");
        ReflectionTestUtils.setField(user, "publicId", UUID.randomUUID());
        user.setRole(UserRole.DRIVER);
        Driver driver = new Driver(user, "LIC-TEST-" + id);
        ReflectionTestUtils.setField(driver, "id", id);
        return driver;
    }
}
