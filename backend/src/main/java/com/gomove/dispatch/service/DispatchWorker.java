package com.gomove.dispatch.service;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(prefix = "gomove.dispatch", name = "enabled", havingValue = "true", matchIfMissing = true)
public class DispatchWorker {
    private static final Logger log = LoggerFactory.getLogger(DispatchWorker.class);
    private final DispatchCoordinator coordinator;

    public DispatchWorker(DispatchCoordinator coordinator) { this.coordinator = coordinator; }

    @Scheduled(fixedDelayString = "${gomove.dispatch.poll-interval-ms:1000}")
    public void poll() {
        try {
            coordinator.runBatch();
        } catch (RuntimeException ex) {
            log.error("Dispatch poll failed; next poll will retry durable database state", ex);
        }
    }
}
