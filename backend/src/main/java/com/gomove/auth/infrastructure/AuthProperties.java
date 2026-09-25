package com.gomove.auth.infrastructure;
import org.springframework.boot.context.properties.ConfigurationProperties;
import java.time.Duration;
@ConfigurationProperties(prefix="gomove.auth")
public class AuthProperties {
    private String jwtSecret; private Duration accessTokenValidity=Duration.ofMinutes(15); private Duration refreshTokenValidity=Duration.ofDays(30); private int maxFailedLoginAttempts=5; private Duration lockDuration=Duration.ofMinutes(15);
    public String getJwtSecret(){return jwtSecret;} public void setJwtSecret(String v){jwtSecret=v;} public Duration getAccessTokenValidity(){return accessTokenValidity;} public void setAccessTokenValidity(Duration v){accessTokenValidity=v;} public Duration getRefreshTokenValidity(){return refreshTokenValidity;} public void setRefreshTokenValidity(Duration v){refreshTokenValidity=v;} public int getMaxFailedLoginAttempts(){return maxFailedLoginAttempts;} public void setMaxFailedLoginAttempts(int v){maxFailedLoginAttempts=v;} public Duration getLockDuration(){return lockDuration;} public void setLockDuration(Duration v){lockDuration=v;}
}
