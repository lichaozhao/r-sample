calc_min_max_date
Purpose: Given a set of date fields in the input data, compute a standardized min and max date window to anchor SDTM domain date calculations.
Inputs: A data frame with date-like columns (e.g., start_date, end_date, visit_date) or a single date field with context to determine a range.
Outputs: A data frame or a list containing the computed min and max dates, with metadata about the calculation method (e.g., inclusive/exclusive window, date format normalization).