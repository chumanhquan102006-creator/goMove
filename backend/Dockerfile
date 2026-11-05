FROM maven:3.9-eclipse-temurin-21@sha256:2b4496088e7b80ae10a8c9f74e574ea21380325a006ec684532ad6bad5bc7273 AS build
WORKDIR /src
COPY .mvn/ .mvn/
COPY mvnw pom.xml ./
COPY src/ src/
COPY docker/ docker/
RUN chmod +x mvnw \
    && MAVEN_CONFIG= ./mvnw -B -ntp -Dmaven.test.skip=true package \
    && javac -d /tmp/health docker/HealthProbe.java \
    && cp target/gomove-backend-0.0.1-SNAPSHOT.jar /tmp/app.jar

FROM eclipse-temurin:21-jre@sha256:0b99b3376fbb50dbf9c0af8535fdd5b8eb0d3fdfc8b1e4967f383b6919f6901a
WORKDIR /app
COPY --from=build /tmp/app.jar /app/app.jar
COPY --from=build /tmp/health/ /app/health/
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
