# Launcher: runs the pre-registered collection for ONE model family.
# Start it with RStudio's "Source as Background Job" (working directory = project).
# Safe to stop and restart: finished calls are skipped.
source("main_study.R")
run("openai")
