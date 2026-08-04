/* C-ядро PSVR2: чтение SLAM-поз шлема через libusb (протокол из драйвера Monado). */
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* Запуск: открывает устройство, захватывает интерфейсы, стартует поток чтения.
 * Возвращает 0 при успехе. */
int psvr2_start(void);

void psvr2_stop(void);

/* 1 — шлем подключён и позы поступают. */
int psvr2_connected(void);

/* Последний сырой SLAM-кватернион и позиция.
 * quat_wxyz: w, x, y, z как в USB-пакете; pos_xyz: метры. Возвращает 1, если поза валидна. */
int psvr2_get_pose(float quat_wxyz[4], float pos_xyz[3]);

/* Датчик приближения (шлем надет) и IPD в мм. */
int psvr2_get_status(int *proximity, int *ipd_mm);

/* Угловая скорость (рад/с, оси как у кватерниона после маппинга Monado)
 * и возраст последней SLAM-позы в секундах — для предсказания. */
int psvr2_get_motion(float gyro_radps[3], double *slam_age_s);

/* Предсказанный кватернион: последняя SLAM-поза, доинтегрированная всеми
 * IMU-сэмплами после неё (по общим VTS-таймстампам) плюс экстраполяция
 * на lookahead_s вперёд. Кватернион УЖЕ в осях Monado-маппинга
 * (x-вправо, y-вверх, -z-вперёд до поправки на 90°); remap в вызывающем
 * коде не нужен. Возвращает 1, если поза валидна. */
int psvr2_get_predicted_quat(float lookahead_s, float out_wxyz[4]);

/* Кнопка Fn на шлеме: 1 — нажата. */
int psvr2_get_button(void);

/* Яркость дисплея 0..1. */
int psvr2_set_brightness(float brightness);

/* 8 параметров дисторсии, посчитанных из калибровки шлема (как в Monado). */
int psvr2_get_distortion_calibration(float out[8]);

/* Указатель на LUT 1024x3 float (r,g,b). */
const float *psvr2_distortion_lut(void);

#ifdef __cplusplus
}
#endif
