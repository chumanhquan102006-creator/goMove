package com.gomove.common.exception;

import org.springframework.http.HttpStatus;

public class DomainException extends BaseException {
    public DomainException(String code, String message) {
        super(HttpStatus.BAD_REQUEST, code, message);
    }

    public DomainException(HttpStatus status, String code, String message) {
        super(status, code, message);
    }
}
