package com.gomove.admin.api;

import java.util.List;

public record AdminPage<T>(List<T> items, int page, int size, long total) {}
