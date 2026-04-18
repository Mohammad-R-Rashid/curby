// ============================================================
// Zod Validation Schemas
// ============================================================

import { z } from 'zod';

export const TelemetryPayloadSchema = z.object({
  userId: z.string().min(1),
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  speed: z.number().min(0),
  heading: z.number().min(0).max(360),
  accuracy: z.number().min(0),
  timestamp: z.string().datetime(),
});

export const ParkEventSchema = z.object({
  userId: z.string().min(1),
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  timestamp: z.string().datetime(),
});

export const DepartEventSchema = z.object({
  userId: z.string().min(1),
  timestamp: z.string().datetime(),
});

export const FindParkingSchema = z.object({
  type: z.literal('find_parking'),
  destLat: z.number().min(-90).max(90),
  destLng: z.number().min(-180).max(180),
  radius: z.number().min(100).max(10000).optional(),
});

export const ArrivedSchema = z.object({
  type: z.literal('arrived'),
  sessionId: z.string().uuid(),
});

export const CancelSchema = z.object({
  type: z.literal('cancel'),
  sessionId: z.string().uuid(),
});

export const WSCommandSchema = z.discriminatedUnion('type', [
  FindParkingSchema,
  ArrivedSchema,
  CancelSchema,
  z.object({ type: z.literal('accept_update'), sessionId: z.string().uuid() }),
  z.object({ type: z.literal('reject_update'), sessionId: z.string().uuid() }),
  z.object({ type: z.literal('heartbeat') }),
]);
