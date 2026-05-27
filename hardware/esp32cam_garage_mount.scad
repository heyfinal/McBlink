// esp32cam_garage_mount.scad
// Garage door mount for AI-Thinker ESP32-CAM + ESP32-CAM-MB assembly
//
// ORIENTATION: back face (with lens aperture) goes AGAINST the garage door.
//              Lens aligns with a 16mm hole drilled through the door panel.
//              VHB tape applied to the two side flanges.
//
// PRINT SETTINGS:
//   Material : PETG or ASA (temperature stable in garage)
//   Layer    : 0.20 mm
//   Infill   : 25%, gyroid
//   Walls    : 3 perimeters
//   Supports : None required
//   Est. time: ~50 min at 60 mm/s
//
// HARDWARE:
//   - 3M VHB 5952 (1" wide, gray) automotive tape applied to both flanges
//   - Step/unibit drill bit set to 16mm for garage door hole

$fn = 48;

// ── Board assembly dimensions ────────────────────────────────────────────────
// AI-Thinker ESP32-CAM: 27 × 40.5 × ~4.5 mm (PCB)
// ESP32-CAM-MB:         27 × 24.0 × ~4.0 mm (PCB)
// Stacked total (MB plugged into bottom of CAM via header pins):
BOARD_W  = 27.0;   // PCB width
BOARD_H  = 65.0;   // stacked height (40.5 + 24 + header pin clearance)
BOARD_D  = 14.5;   // max depth including tallest capacitors / antenna on MB

// ── Tolerances & walls ──────────────────────────────────────────────────────
TOL       = 0.4;   // XY fit clearance per side (tune ±0.2 for your printer)
WALL      = 3.0;   // side/top/bottom wall thickness
BACK_W    = 2.5;   // back face thickness (door side)

// ── Derived pocket dims ──────────────────────────────────────────────────────
PKT_W = BOARD_W + TOL * 2;
PKT_H = BOARD_H + TOL * 2;
PKT_D = BOARD_D + TOL;

// ── Outer body ───────────────────────────────────────────────────────────────
OUT_W = PKT_W + WALL * 2;   // total body width
OUT_H = PKT_H + WALL * 2;   // total body height
OUT_D = PKT_D + BACK_W;     // total body depth

// ── VHB tape flanges (left and right of body) ────────────────────────────────
FLANGE_EXT = 22.0;          // flange extension beyond body edge
FLANGE_T   = 2.5;           // flange thickness (coplanar with back face)
FLANGE_Y   = OUT_H * 0.18;  // start Y (skip area near lens)
FLANGE_H   = OUT_H * 0.64;  // flange span height

// ── Lens aperture (OV2640 M12 lens position on ESP32-CAM PCB) ────────────────
// From PCB top-left corner: ~13.5 mm right, ~8 mm down
// If image is mirrored/rotated after print, adjust LENS_PCB_X.
LENS_PCB_X         = 13.5;  // from left edge of PCB
LENS_PCB_Y_FROM_TOP =  8.0;  // from top edge of PCB
LENS_D             = 14.0;  // aperture diameter (M12 barrel is ~12 mm; +2 clearance)

// Lens center in mount coordinates (origin = bottom-left of back face)
LENS_AX = WALL + TOL + LENS_PCB_X;
LENS_AY = OUT_H - WALL - TOL - LENS_PCB_Y_FROM_TOP;

// ── USB notch (bottom opening for ESP32-CAM-MB micro-USB port) ───────────────
USB_W = 11.0;   // micro-USB connector width + clearance
USB_H =  7.5;   // height of notch opening
// USB port centered on board width, at top of MB board = near bottom of assembly
USB_X = WALL + TOL + (BOARD_W - USB_W) / 2;

// ── Retention lips (front-opening lips that keep board from falling out) ──────
LIP_D    = 1.2;   // lip protrusion into pocket
LIP_H    = 2.0;   // lip height
LIP_SPAN = 22.0;  // span of each lip (centered on side wall)

// ────────────────────────────────────────────────────────────────────────────
module esp32cam_mount() {
    difference() {
        union() {
            // Main shell: back face + four walls, open front face
            difference() {
                cube([OUT_W, OUT_H, OUT_D]);
                // Board pocket (open from front = Z-max face)
                translate([WALL, WALL, BACK_W])
                    cube([PKT_W, PKT_H, PKT_D + 1]);
            }

            // Left VHB flange (flush with back face, extends left)
            translate([-FLANGE_EXT, FLANGE_Y, 0])
                cube([FLANGE_EXT, FLANGE_H, FLANGE_T]);

            // Right VHB flange
            translate([OUT_W, FLANGE_Y, 0])
                cube([FLANGE_EXT, FLANGE_H, FLANGE_T]);
        }

        // Lens aperture through back face
        translate([LENS_AX, LENS_AY, -0.1])
            cylinder(d = LENS_D, h = BACK_W + 0.2);

        // USB notch: slot through bottom wall for micro-USB access
        translate([USB_X, -0.1, BACK_W + PKT_D - USB_H])
            cube([USB_W, WALL + 0.2, USB_H + 0.5]);

        // Vent slots, left wall (thermal relief for ESP32 SoC)
        for (i = [0 : 2])
            translate([-0.1, WALL * 2.5 + i * 14, BACK_W + 3])
                cube([WALL + 0.2, 6, 4]);

        // Vent slots, right wall
        for (i = [0 : 2])
            translate([OUT_W - 0.1, WALL * 2.5 + i * 14, BACK_W + 3])
                cube([WALL + 0.2, 6, 4]);
    }

    // Retention lips at front opening (left and right inner walls)
    // These overhang into the pocket to hold board; board press-fits past them.
    translate([WALL - LIP_D,
               OUT_H / 2 - LIP_SPAN / 2,
               BACK_W + PKT_D - LIP_H])
        cube([LIP_D, LIP_SPAN, LIP_H]);

    translate([WALL + PKT_W,
               OUT_H / 2 - LIP_SPAN / 2,
               BACK_W + PKT_D - LIP_H])
        cube([LIP_D, LIP_SPAN, LIP_H]);
}

esp32cam_mount();

// ── Drill guide (separate flat piece, print once and discard after drilling) ──
// Tape to outside of garage door, drill through center circle for lens hole.
// Uncomment the translate below and comment out esp32cam_mount() to generate.

// DOOR_HOLE_D = 16.0;   // step bit target diameter
// translate([OUT_W + 10, 0, 0])
//     difference() {
//         cube([OUT_W, OUT_H, 2]);
//         translate([LENS_AX, LENS_AY, -0.1])
//             cylinder(d = DOOR_HOLE_D, h = 3);
//         // Corner mounting holes for tape (optional)
//         for (x = [5, OUT_W - 5]) for (y = [5, OUT_H - 5])
//             translate([x, y, -0.1]) cylinder(d = 2, h = 3);
//     }
