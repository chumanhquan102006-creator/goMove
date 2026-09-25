package com.gomove.common.exception;
import org.springframework.http.HttpStatus;
public class BaseException extends RuntimeException {
    private final String code; private final HttpStatus status;
    public BaseException(HttpStatus status, String code, String message) { super(message); this.status = status; this.code = code; }
    public String getCode() { return code; } public HttpStatus getStatus() { return status; }
}
