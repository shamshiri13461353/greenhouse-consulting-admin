-- Make the configured service catalog available for free request submission.
-- Pricing is still quoted by the company after review; no price is fabricated here.
update public.services
set is_active = true
where code in (
  'combined_lab_nutrition',
  'consultation_case',
  'irrigation_water_drainage_analysis',
  'nutrition_recommendation',
  'plant_tissue_analysis',
  'soil_analysis',
  'substrate_analysis'
);
