import { defineCollection, z } from "astro:content";

const projects = defineCollection({
  schema: z.object({
    title: z.string(),
    date: z.coerce.date(),
    summary: z.string(),
    stack: z.array(z.string()).default([]),
  }),
});

export const collections = { projects };