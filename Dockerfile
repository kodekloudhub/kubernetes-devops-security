FROM eclipse-temurin:21-jre
WORKDIR /home/k8s-pipeline
EXPOSE 8080
ARG JAR_FILE=target/*.jar
RUN groupadd --system pipeline && \
    useradd --system --gid pipeline k8s-pipeline
COPY ${JAR_FILE} app.jar
USER k8s-pipeline
ENTRYPOINT ["java", "-jar", "app.jar"]
