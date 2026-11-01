package com.gomove.admin.infrastructure;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.UUID;

@Repository
public class AdminAuditStore {
    private final JdbcTemplate jdbc;

    public AdminAuditStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public void recordDriverApproval(UUID adminId, UUID driverId, String before, String after) {
        jdbc.update("""
                INSERT INTO admin_action_audit
                    (admin_user_public_id, target_public_id, action_type, previous_status, new_status, outcome)
                VALUES (?, ?, 'DRIVER_APPROVAL_STATUS', ?, ?, ?)
                """, adminId, driverId, before, after,
                before.equals(after) ? "UNCHANGED" : "APPLIED");
    }
}
