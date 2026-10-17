extends CharacterBody2D
## Test fixture: typed exports and setters for the property writer tests.

@export var speed: float = 100.0
@export var icon: Texture2D
@export var items: Array[Texture2D] = []
@export var next_level: String = ""
@export var target: Node2D
@export var clamped: int = 0:
	set(v):
		clamped = clampi(v, 0, 10)
@export var locked: int = 5:
	set(_v):
		pass
var health := 3
