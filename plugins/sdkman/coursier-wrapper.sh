#!/usr/bin/env bash
set -euo pipefail

exec @JAVA@/bin/java -jar @COURSIER_JAR@/share/java/coursier.jar "$@"
