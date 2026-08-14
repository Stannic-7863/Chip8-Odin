package main

import "core:fmt"
import "core:math/rand"
import "base:intrinsics"
import "core:log"
import "base:runtime"
import "core:os"
import rl "vendor:raylib"

Vec2i32 :: [2]i32

/*

16 8-bit registers labelled V0 to VF (Convenient, because remove the V prefix and we have our register index)
register F is special purpose

4096 astounding bytes of memory

0x000-0x1FF range reserved for chip-8 interpreter. In emulater we shall not write to this region.
0x050-0xA0  range reserved for 16 built-in characters.
0x200-0xFFF range reserved for rom. Free riel estate.

index_register holds memory addresses
program_counter holds memory address of next instruction to execute.
- Memory is addressed as byte. Aka word size = byte. Aka we can only fetch one byte at a time. But instructions are two bytes.
  So we fetch a byte at pc and a byte at pc + 1, and now we have our complete instruction fetched. We then increment pc by 2 to make it point to next instruction.

32 bytes of stack. we use two bytes at a time to hold a single memory address. stack is soley used for function calls. Max depth of function calls 16 level
stack pointer keeps track of where we at in the stack, its a single byte because the max value it'll hold is 15.

delay timer decrements at 60Hz if its value is not 0, otherwise it just stays 0.
sound timer decrements at 60Hz if its value is not 0, otherwise it just stays 0. A single tone sound plays while its not 0.
keys has 16 input keys. labeled 0 to F. Key either pressed or nah.

64x32, 2:1 ratio display. Given a sprite, we take its pixels and xor them with the screen pixels.

*/

Chip8 :: struct {
	display:         [32][64]byte,
	memory:          [4096]byte,
	stack:           [16]u16,
	registers:       [16]byte,
	keys:            [16]byte,
	opcode:          u16, // I could make it an enum. But I wanna try implementing this via LUT so u16 index shall do.
	index_register:  u16,
	program_counter: u16,
	stack_pointer:   u8,
	delay_timer:     u8,
	sound_timer:     u8,
}

DEFAULT_FONT := []u8 {
	0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
	0x20, 0x60, 0x20, 0x20, 0x70, // 1
	0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
	0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
	0x90, 0x90, 0xF0, 0x10, 0x10, // 4
	0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
	0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
	0xF0, 0x10, 0x20, 0x40, 0x40, // 7
	0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
	0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
	0xF0, 0x90, 0xF0, 0x90, 0x90, // A
	0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
	0xF0, 0x80, 0x80, 0x80, 0xF0, // C
	0xE0, 0x90, 0x90, 0x90, 0xE0, // D
	0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
	0xF0, 0x80, 0xF0, 0x80, 0x80, // F
}

chip8_00E0 :: proc(chip: ^Chip8) { // Clear screen to 0
	chip.display = 0
}

chip8_00EE :: proc(chip: ^Chip8) {
	chip.stack_pointer -= 1
	chip.program_counter = chip.stack[chip.stack_pointer]
}

chip8_1nnn :: proc(chip: ^Chip8) { // Jump at nnn. basically set the program counter to there
	chip.program_counter = chip.opcode & 0x0FFF;
}

chip8_2nnn :: proc(chip: ^Chip8) { // Call subroutine at nnn. Push current program counter to stack and set program counter to nnn
	chip.stack[chip.stack_pointer] = chip.program_counter;
	chip.stack_pointer += 1
	chip.program_counter = chip.opcode & 0xFFF;
}

chip8_3xkk :: proc(chip: ^Chip8) { // Skip next instruction (pc += 2) if register X == kk
	if byte(chip.opcode & 0x00FF) == chip.registers[(chip.opcode >> 8) & 0x000F] {
		chip.program_counter += 2
	}
}

chip8_4xkk :: proc(chip: ^Chip8) { // skip next instruction (pc += 2) if register X != kk
	if byte(chip.opcode & 0x00FF) != chip.registers[(chip.opcode >> 8) & 0x000F] {
		chip.program_counter += 2
	}
}

chip8_5xy0 :: proc(chip: ^Chip8) { // skip next instruction (pc += 2) is register x == register y
	if chip.registers[chip.opcode >> 8 & 0x000F] == chip.registers[(chip.opcode >> 4) & 0x000F] {
		chip.program_counter += 2
	}
}

chip8_6xkk :: proc(chip: ^Chip8) { // set register X to kk
	chip.registers[(chip.opcode >> 8) & 0x000F] = byte(chip.opcode & 0x00FF)
}

chip8_7xkk :: proc(chip: ^Chip8) { // add to register X kk
	chip.registers[(chip.opcode >> 8) & 0x000F] += byte(chip.opcode & 0x00FF)
}

chip8_8xy0 :: proc(chip: ^Chip8) { // Set register x value to register y
	chip.registers[(chip.opcode >> 8) & 0x000F] = chip.registers[(chip.opcode >> 4) & 0x000F]
}

chip8_8xy1 :: proc(chip: ^Chip8) { // set register X value to register Y | register X
	chip.registers[(chip.opcode >> 8) & 0x000F] |= chip.registers[(chip.opcode >> 4) & 0x000F]
}

chip8_8xy2 :: proc(chip: ^Chip8) { // set register X value to register Y & register X
	chip.registers[(chip.opcode >> 8) & 0x000F] &= chip.registers[(chip.opcode >> 4) & 0x000F]
}

chip8_8xy3 :: proc(chip: ^Chip8) { // set register X value to register Y ~ register X
	chip.registers[(chip.opcode >> 8) & 0x000F] ~= chip.registers[(chip.opcode >> 4) & 0x000F]
}

chip8_8xy4 :: proc(chip: ^Chip8) { // set register X value to register Y + register X. set register F to overflow
	x := &chip.registers[(chip.opcode >> 8) & 0x000F]
	y := chip.registers[(chip.opcode >> 4) & 0x000F]
	result, overflow := intrinsics.overflow_add(x^, y)
	x^ = result
	chip.registers[0xF] = byte(overflow)
}

chip8_8xy5 :: proc(chip: ^Chip8) { // set register X value to register X - register Y. set register F to not borrow
	x := &chip.registers[(chip.opcode >> 8) & 0x000F]
	y := chip.registers[(chip.opcode >> 4) & 0x000F]
	x^ -= y
	chip.registers[0xF] = byte(x^ > y)
}

chip8_8xy6 :: proc(chip: ^Chip8) { // Save least significat bit of register x into register F then divide register x by two
	x := &chip.registers[(chip.opcode >> 8) & 0x000F]
	chip.registers[0xF] = x^ & 0x1
	x^ >>= 1
}

chip8_8xy7 :: proc(chip: ^Chip8) { // Set register X value to register Y - register X. set register F to not borrow
	x := &chip.registers[(chip.opcode >> 8) & 0x000F]
	y := chip.registers[(chip.opcode >> 4) & 0x000F]
	x^ = y - x^
	chip.registers[0xF] = byte(x^ < y)
}

chip8_8xyE :: proc(chip: ^Chip8) { // Save most significant bit of register x into register F then multiply registe x by two
	x := &chip.registers[(chip.opcode >> 8) & 0x000F]
	chip.registers[0xF] = (x^ >> 7) & 0x1
	x^ <<= 1
}

chip8_9xy0 :: proc(chip: ^Chip8) { // Skip next instruction if register X != register Y
	if chip.registers[chip.opcode >> 8 & 0x000F] != chip.registers[(chip.opcode >> 4) & 0x000F] {
		chip.program_counter += 2
	}
}

chip8_Annn :: proc(chip: ^Chip8) { // Set index register to nnn
	chip.index_register = chip.opcode & 0x0FFF
}

chip8_Bnnn :: proc(chip: ^Chip8) { // set program counter to Register 0 + nnn
	chip.program_counter += u16(chip.registers[0]) + chip.opcode & 0x0FFF;
}

chip8_Cxkk :: proc(chip: ^Chip8) { // register X = random_byte & kk
	chip.registers[(chip.opcode >> 8) & 0x00F] = byte(rand.uint32_range(0, 255)) & (byte(chip.opcode & 0x0FF))
}

chip8_Dxyn :: proc(chip: ^Chip8) { // draw a sprite of n bytes from register x to register y. N = height, 8 = width of sprite

	x, y := chip.registers[(chip.opcode >> 8) & 0xF], chip.registers[(chip.opcode >> 4) & 0xF]

	chip.registers[0xF] = 0

	for row := byte(0); row < byte(chip.opcode & 0x000F); row += 1 {
		sprite_row := chip.memory[chip.index_register + u16(row)]
		for col := byte(0); col < 8; col += 1 {
			sprite_pixel := ((sprite_row >> (7 - col)) & 0x1)
			if sprite_pixel == 0 { continue }
			display_pixel := &chip.display[(y + row) % 32][(x + col) % 64]

			if display_pixel^ == 1 && sprite_pixel == 1 {
				chip.registers[0xF] = 1
			}

			display_pixel^ ~= 1
		}
	}
}

chip8_Ex9E :: proc(chip: ^Chip8) {
	if chip.keys[chip.registers[(chip.opcode >> 8) & 0xF]] == 1 {
		chip.program_counter += 2
	}
}

chip8_ExA1 :: proc(chip: ^Chip8) {
	if chip.keys[chip.registers[(chip.opcode >> 8) & 0xF]] == 0 {
		chip.program_counter += 2
	}
}

chip8_Fx07 :: proc(chip: ^Chip8) {
	chip.registers[(chip.opcode >> 8) & 0xF] = chip.delay_timer
}

chip8_Fx0A :: proc(chip: ^Chip8) { // Wait until a key is pressed. If pressed store its value in register Vx
	for k, i in chip.keys {
		if k == 1 {
			chip.registers[(chip.opcode >> 8) & 0xF] = byte(i)
			return
	 	}
	}
	chip.program_counter -= 2
}

chip8_Fx15 :: proc(chip: ^Chip8) { // Set delay timer to register x
	chip.delay_timer = chip.registers[(chip.opcode >> 8) & 0xF]
}

chip8_Fx18 :: proc(chip: ^Chip8) { // Set sound timer to register x
	chip.sound_timer = chip.registers[(chip.opcode >> 8) & 0xF]
}

chip8_Fx1E :: proc(chip: ^Chip8) { // Set index register to index register + register x
	chip.index_register += u16(chip.registers[(chip.opcode >> 8) & 0xF])
}

chip8_Fx29 :: proc(chip: ^Chip8) { // Set delay timer to register x
	// set index register = font character for x
	chip.index_register = 0x050 + u16(chip.registers[(chip.opcode >> 8) & 0xF])
}

chip8_fx33 :: proc(chip: ^Chip8) { // Store bcd of register x in memory location I..<I+3
	value := chip.registers[(chip.opcode >> 8) & 0xF]
	chip.memory[chip.index_register + 2] = value % 10
	value /= 10
	chip.memory[chip.index_register + 1] = value % 10
	value /= 10
	chip.memory[chip.index_register + 0] = value % 10
}

chip8_fx55 :: proc(chip: ^Chip8) { // store register 0..<x into memory starting from index register
	to_copy := (chip.opcode >> 8) & 0xF + 1
	copy(chip.memory[chip.index_register:chip.index_register + to_copy], chip.registers[:to_copy])
}

chip8_fx65 :: proc(chip: ^Chip8) { // read register 0..<x from memory starting from index regiseter
	to_copy := (chip.opcode >> 8) & 0xF + 1
	copy(chip.registers[:to_copy], chip.memory[chip.index_register:chip.index_register + to_copy])
}

chip8_create :: proc() -> Chip8 {
	chip := Chip8 { program_counter = 0x200 }
	chip.keys = 0xFF
	for b, i in DEFAULT_FONT {
		chip.memory[0x050 + i] = b
	}

	return chip
}

chip8_load_rom :: proc(chip: ^Chip8, path: string, allocator: runtime.Allocator) -> (ok: bool) {
	data, read_err := os.read_entire_file_from_path(path, allocator)
	defer delete(data, allocator)

	if read_err != nil {
		log.error(read_err)
		return false
	}

	for b, i in data {
		chip.memory[0x200 + i] = b
	}

	return true
}

table_0 :: proc(chip: ^Chip8) {
	unique := chip.opcode & 0x000F

	switch unique {
	case 0x0: table[16 + 9 + 0](chip)
	case 0xE: table[16 + 9 + 1](chip)
	}
}

table_8 :: proc(chip: ^Chip8) {
	unique := chip.opcode & 0x000F
	switch unique {
	case 0x0..=0x7: table[16 + unique](chip)
	case 0xE:      table[24](chip)
	}
}

table_E :: proc(chip: ^Chip8) {
	unique := chip.opcode & 0x000F

	// Ex9E / ExA1
	switch unique {
	case 0xE: table[16 + 9 + 2 + 0](chip) // Ex9E
	case 0x1: table[16 + 9 + 2 + 1](chip) // ExA1
	}
}

table_F :: proc(chip: ^Chip8) {
	switch chip.opcode & 0x00FF {
	case 0x07: table[16 + 9 + 2 + 2 + 0](chip) // Fx07
	case 0x0A: table[16 + 9 + 2 + 2 + 1](chip) // Fx0A
	case 0x15: table[16 + 9 + 2 + 2 + 2](chip) // Fx15
	case 0x18: table[16 + 9 + 2 + 2 + 3](chip) // Fx18
	case 0x1E: table[16 + 9 + 2 + 2 + 4](chip) // Fx1E
	case 0x29: table[16 + 9 + 2 + 2 + 5](chip) // Fx29
	case 0x33: table[16 + 9 + 2 + 2 + 6](chip) // Fx33
	case 0x55: table[16 + 9 + 2 + 2 + 7](chip) // Fx55
	case 0x65: table[16 + 9 + 2 + 2 + 8](chip) // Fx65
	}
}

table := [38]proc(chip: ^Chip8) {
	table_0,
	chip8_1nnn,
	chip8_2nnn,
	chip8_3xkk,
	chip8_4xkk,
	chip8_5xy0,
	chip8_6xkk,
	chip8_7xkk,
	table_8,
	chip8_9xy0,
	chip8_Annn,
	chip8_Bnnn,
	chip8_Cxkk,
	chip8_Dxyn,
	table_E,
	table_F,

	chip8_8xy0,
	chip8_8xy1,
	chip8_8xy2,
	chip8_8xy3,
	chip8_8xy4,
	chip8_8xy5,
	chip8_8xy6,
	chip8_8xy7,
	chip8_8xyE,

	chip8_00E0,
	chip8_00EE,

	chip8_Ex9E,
	chip8_ExA1,

	chip8_Fx07,
	chip8_Fx0A,
	chip8_Fx15,
	chip8_Fx18,
	chip8_Fx1E,
	chip8_Fx29,
	chip8_fx33,
	chip8_fx55,
	chip8_fx65,
}

chip8_cycle :: proc(chip: ^Chip8) {
	chip.opcode = u16(chip.memory[chip.program_counter]) << 8 | u16(chip.memory[chip.program_counter + 1])
	chip.program_counter += 2

	table[(chip.opcode >> 12) & 0xF](chip)

	if chip.delay_timer > 0 { chip.delay_timer -= 1 }
	if chip.sound_timer > 0 { chip.sound_timer -= 1 }
}

main :: proc() {
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

	chip := chip8_create()
	chip8_load_rom(&chip, os.args[1], context.allocator)

	scale := i32(20)

	rl.InitWindow(64 * scale, 32 * scale, "chip8")
	defer rl.CloseWindow()

	rl.SetTargetFPS(60)

	for !rl.WindowShouldClose() {
		chip.keys[0x1] = byte(rl.IsKeyDown(.ONE))
		chip.keys[0x2] = byte(rl.IsKeyDown(.TWO))
		chip.keys[0x3] = byte(rl.IsKeyDown(.THREE))
		chip.keys[0xC] = byte(rl.IsKeyDown(.FOUR))

		chip.keys[0x4] = byte(rl.IsKeyDown(.Q))
		chip.keys[0x5] = byte(rl.IsKeyDown(.W))
		chip.keys[0x6] = byte(rl.IsKeyDown(.E))
		chip.keys[0xD] = byte(rl.IsKeyDown(.R))

		chip.keys[0x7] = byte(rl.IsKeyDown(.A))
		chip.keys[0x8] = byte(rl.IsKeyDown(.S))
		chip.keys[0x9] = byte(rl.IsKeyDown(.D))
		chip.keys[0xE] = byte(rl.IsKeyDown(.F))

		chip.keys[0xA] = byte(rl.IsKeyDown(.Z))
		chip.keys[0x0] = byte(rl.IsKeyDown(.X))
		chip.keys[0xB] = byte(rl.IsKeyDown(.C))
		chip.keys[0xF] = byte(rl.IsKeyDown(.V))

		chip8_cycle(&chip)

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)

		for r := i32(0); r < 32; r += 1 {
			for c := i32(0); c < 64; c += 1 {
				if chip.display[r][c] == 1 {
					rl.DrawRectangle(c * scale, r * scale, scale, scale, rl.WHITE)
				}
			}
		}

		rl.EndDrawing()
	}
}
