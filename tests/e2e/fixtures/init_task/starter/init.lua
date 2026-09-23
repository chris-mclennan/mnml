-- Runs while mnml builds its App, before the first frame: the shape of
-- a startup build watcher or linter.
mnml.task.run{ cmd = "echo ran > INIT_TASK_RAN", hidden = true }
