package com.kenteretail.orderservice;

import java.util.UUID;

import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.actuate.observability.AutoConfigureObservability;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;

import static org.hamcrest.Matchers.containsString;
import static org.hamcrest.Matchers.not;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

// The near-miss: /actuator/env answered 200 to a scanner and served the DB
// password in plain text. These tests fail the build if that can happen again.
class ActuatorExposureTest {

    @Nested
    @SpringBootTest
    @AutoConfigureMockMvc
    @AutoConfigureObservability
    class WithTheShippedConfig {

        @Autowired
        private MockMvc mvc;

        @Test
        void prometheusAndHealthAreExposed() throws Exception {
            mvc.perform(get("/actuator/prometheus")).andExpect(status().isOk());
            mvc.perform(get("/actuator/health")).andExpect(status().isOk());
        }

        @Test
        void sensitiveEndpointsAreNotExposed() throws Exception {
            for (String path : new String[] {"/actuator/env", "/actuator/heapdump", "/actuator/configprops", "/actuator/beans"}) {
                mvc.perform(get(path)).andExpect(status().isNotFound());
            }
        }

        @Test
        void discoveryPageDoesNotListEndpoints() throws Exception {
            mvc.perform(get("/actuator")).andExpect(status().isNotFound());
        }
    }

    // Second line of defence: someone widens the exposure anyway. The value
    // must still come back masked. The fake value is made at runtime, so the
    // secret scanner never sees a literal in this file.
    @Nested
    @SpringBootTest(properties = "management.endpoints.web.exposure.include=env")
    @AutoConfigureMockMvc
    class WithEnvExposedByMistake {

        private static final String FAKE_SECRET = "fake-" + UUID.randomUUID();

        @DynamicPropertySource
        static void fakeSecret(DynamicPropertyRegistry registry) {
            registry.add("DB_PASSWORD", () -> FAKE_SECRET);
        }

        @Autowired
        private MockMvc mvc;

        @Test
        void envValuesStayMasked() throws Exception {
            mvc.perform(get("/actuator/env"))
                    .andExpect(status().isOk())
                    .andExpect(content().string(not(containsString(FAKE_SECRET))))
                    .andExpect(content().string(containsString("******")));
        }
    }
}
