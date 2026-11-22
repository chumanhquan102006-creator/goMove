package com.gomove.dispatch.service;

import jakarta.validation.Validation;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class DispatchPropertiesTest {
    @Test void defaultsAreOptInAndFiftyMeters() {
        DispatchProperties properties = new DispatchProperties();
        assertThat(properties.isReputationTieBreakEnabled()).isFalse();
        assertThat(properties.getNearEqualMeters()).isEqualTo(50);
    }

    @Test void bandRejectsNegativeAndExcessiveValues() {
        try (var factory = Validation.buildDefaultValidatorFactory()) {
            var validator = factory.getValidator();
            var properties = new DispatchProperties();
            for (int band : new int[]{-1, 5001}) {
                properties.setNearEqualMeters(band);
                assertThat(validator.validate(properties)).anySatisfy(violation ->
                        assertThat(violation.getPropertyPath().toString()).isEqualTo("nearEqualMeters"));
            }
            for (int band : new int[]{0, 50, 5000}) {
                properties.setNearEqualMeters(band);
                assertThat(validator.validate(properties)).isEmpty();
            }
        }
    }
}
