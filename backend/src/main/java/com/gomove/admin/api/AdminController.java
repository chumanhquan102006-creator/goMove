package com.gomove.admin.api;

import com.gomove.admin.service.AdminQueryService;
import com.gomove.common.api.ApiResponse;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/v1/admin")
@PreAuthorize("hasRole('ADMIN')")
public class AdminController {
    private final AdminQueryService service;

    public AdminController(AdminQueryService service) { this.service = service; }

    @GetMapping("/dashboard")
    public ApiResponse<AdminDashboard> dashboard() {
        return ApiResponse.success("ADMIN_DASHBOARD", "Admin dashboard", service.dashboard());
    }

    @GetMapping("/drivers")
    public ApiResponse<AdminPage<AdminDriver>> drivers(
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String approvalStatus,
            @RequestParam(required = false) String q) {
        return ApiResponse.success("ADMIN_DRIVERS", "Admin drivers",
                service.drivers(page, size, approvalStatus, q));
    }

    @GetMapping("/drivers/{driverPublicId}")
    public ApiResponse<AdminDriver> driver(@PathVariable UUID driverPublicId) {
        return ApiResponse.success("ADMIN_DRIVER", "Admin driver", service.driver(driverPublicId));
    }

    @GetMapping("/accounts")
    public ApiResponse<AdminPage<AdminAccount>> accounts(
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String role,
            @RequestParam(required = false) String q) {
        return ApiResponse.success("ADMIN_ACCOUNTS", "Admin accounts",
                service.accounts(page, size, role, q));
    }

    @GetMapping("/accounts/{accountPublicId}")
    public ApiResponse<AdminAccount> account(@PathVariable UUID accountPublicId) {
        return ApiResponse.success("ADMIN_ACCOUNT", "Admin account", service.account(accountPublicId));
    }

    @GetMapping("/bookings")
    public ApiResponse<AdminPage<AdminBooking>> bookings(
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String status) {
        return ApiResponse.success("ADMIN_BOOKINGS", "Admin bookings", service.bookings(page, size, status));
    }
}
