extends CharacterBody2D
## Simple enemy that patrols back and forth

@export var patrol_speed := 100.0
@export var patrol_distance := 200.0

var _start_position: Vector2
var _direction := 1.0

func _ready() -> void:
	_start_position = global_position

func _physics_process(delta: float) -> void:
	# Move in current direction
	velocity.x = patrol_speed * _direction

	# Check if we've gone too far
	var distance_from_start := global_position.x - _start_position.x
	if abs(distance_from_start) > patrol_distance:
		_direction *= -1.0

	move_and_slide()
