extends Node
# Toast Notification Manager — autoload singleton.
# Pure event bus for non-intrusive notifications.
#
# A toast reports a result the user cannot otherwise see. It never restates the
# action they just took: a new tile, a closed pane and a swapped type are all
# visible in the grid, and a burst of them (a spawn loop, an API caller) would
# only preempt itself.

const INFO = 0
const WARN = 1
const ERROR = 2

signal toast_requested(data: Dictionary)

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS

func info(text: String, duration: float = 3.0, source := ""):
	toast_requested.emit({text = text, level = INFO, duration = duration, source = source})

func warn(text: String, duration: float = 5.0, source := ""):
	toast_requested.emit({text = text, level = WARN, duration = duration, source = source})

func error(text: String, duration: float = 8.0, source := ""):
	toast_requested.emit({text = text, level = ERROR, duration = duration, source = source})
