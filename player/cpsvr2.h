/* PSVR2 C core: reading headset SLAM poses via libusb (protocol from the Monado driver). */
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* Start: opens the device, claims the interfaces, starts the read thread.
 * Returns 0 on success. */
int psvr2_start(void);

void psvr2_stop(void);

/* 1 — the headset is connected and poses are coming in. */
int psvr2_connected(void);

/* Last raw SLAM quaternion and position.
 * quat_wxyz: w, x, y, z as in the USB packet; pos_xyz: meters. Returns 1 if the pose is valid. */
int psvr2_get_pose(float quat_wxyz[4], float pos_xyz[3]);

/* Proximity sensor (headset is worn) and IPD in mm. */
int psvr2_get_status(int *proximity, int *ipd_mm);

/* Angular velocity (rad/s, axes match the quaternion after Monado mapping)
 * and the age of the last SLAM pose in seconds — for prediction. */
int psvr2_get_motion(float gyro_radps[3], double *slam_age_s);

/* Predicted quaternion: the last SLAM pose, integrated forward with all
 * IMU samples after it (by shared VTS timestamps) plus extrapolation
 * lookahead_s ahead. The quaternion is ALREADY in Monado-mapped axes
 * (x-right, y-up, -z-forward before the 90-degree correction); no remap
 * needed in the caller. Returns 1 if the pose is valid. */
int psvr2_get_predicted_quat(float lookahead_s, float out_wxyz[4]);

/* Fn button on the headset: 1 — pressed. */
int psvr2_get_button(void);

/* Display brightness 0..1. */
int psvr2_set_brightness(float brightness);

/* 8 distortion parameters computed from the headset calibration (as in Monado). */
int psvr2_get_distortion_calibration(float out[8]);

/* Pointer to the 1024x3 float LUT (r,g,b). */
const float *psvr2_distortion_lut(void);

/* --- Headset cameras (passthrough) ---
 * Frames arrive as a pair of 1024x1016 BC4 textures (left and right cameras),
 * 60 Hz. Protocol from PSVR2Toolkit: enabled with vendor command 0x0B,
 * stream on interface 6, EP 0x87, packet signature 'V','I'. */

#define PSVR2_CAM_WIDTH 1024
#define PSVR2_CAM_HEIGHT 1016
/* BC4: 4 bits per pixel */
#define PSVR2_CAM_PLANE_BYTES (PSVR2_CAM_WIDTH * PSVR2_CAM_HEIGHT / 2)

/* Powers on the cameras and starts the read thread. 0 — success. */
int psvr2_camera_start(void);

void psvr2_camera_stop(void);

/* Copies the last frame: left and right are PSVR2_CAM_PLANE_BYTES buffers each.
 * Returns 1 if the frame is new (since the previous call), 0 otherwise. */
int psvr2_camera_get_frame(unsigned char *left, unsigned char *right);

#ifdef __cplusplus
}
#endif
