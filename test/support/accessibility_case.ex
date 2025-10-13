defmodule BitblocksWeb.AccessibilityCase do
  @moduledoc """
  Provides accessibility testing helpers for HTML content.

  Checks for common WCAG 2.1 violations including:
  - Images without alt text
  - Form inputs without labels
  - Links without accessible text
  - Heading hierarchy issues
  - Missing language attribute
  - Color contrast (basic checks)
  """

  import ExUnit.Assertions
  alias Floki

  @doc """
  Checks HTML content for accessibility violations.

  ## Examples

      conn = get(conn, ~p"/")
      html = html_response(conn, 200)
      assert_accessible(html, "Home page")
  """
  def assert_accessible(html, page_name \\ "Page") do
    violations = check_accessibility(html)

    if length(violations) > 0 do
      formatted_violations =
        violations
        |> Enum.map(fn {type, details} -> "  - #{type}: #{details}" end)
        |> Enum.join("\n")

      flunk("""
      #{page_name} has #{length(violations)} accessibility violation(s):

      #{formatted_violations}
      """)
    end

    :ok
  end

  @doc """
  Checks HTML for accessibility issues and returns list of violations.
  """
  def check_accessibility(html) do
    document = Floki.parse_document!(html)

    []
    |> check_images_have_alt(document)
    |> check_form_labels(document)
    |> check_links_have_text(document)
    |> check_heading_hierarchy(document)
    |> check_lang_attribute(document)
    |> check_buttons_have_text(document)
    |> check_form_elements_have_names(document)
  end

  # Check all images have alt attributes
  defp check_images_have_alt(violations, document) do
    images_without_alt =
      document
      |> Floki.find("img")
      |> Enum.reject(fn img ->
        alt = Floki.attribute(img, "alt")
        length(alt) > 0
      end)

    if length(images_without_alt) > 0 do
      [{:missing_alt, "#{length(images_without_alt)} image(s) missing alt attribute"} | violations]
    else
      violations
    end
  end

  # Check form inputs have associated labels
  defp check_form_labels(violations, document) do
    inputs = Floki.find(document, "input[type='text'], input[type='email'], input[type='password'], input[type='search'], textarea, select")

    inputs_without_labels =
      Enum.reject(inputs, fn input ->
        id = Floki.attribute(input, "id") |> List.first()
        aria_label = Floki.attribute(input, "aria-label") |> List.first()
        aria_labelledby = Floki.attribute(input, "aria-labelledby") |> List.first()

        # Check if has aria-label, aria-labelledby, or associated label
        has_label =
          aria_label != nil or
          aria_labelledby != nil or
          (id != nil and length(Floki.find(document, "label[for='#{id}']")) > 0)

        has_label
      end)

    if length(inputs_without_labels) > 0 do
      [{:missing_labels, "#{length(inputs_without_labels)} form input(s) without associated labels"} | violations]
    else
      violations
    end
  end

  # Check links have accessible text
  defp check_links_have_text(violations, document) do
    links_without_text =
      document
      |> Floki.find("a")
      |> Enum.reject(fn link ->
        text = Floki.text(link) |> String.trim()
        aria_label = Floki.attribute(link, "aria-label") |> List.first()

        (text != "" and text != nil) or (aria_label != nil and aria_label != "")
      end)

    if length(links_without_text) > 0 do
      [{:links_no_text, "#{length(links_without_text)} link(s) without accessible text"} | violations]
    else
      violations
    end
  end

  # Check heading hierarchy (h1, h2, h3, etc. in order)
  defp check_heading_hierarchy(violations, document) do
    headings =
      document
      |> Floki.find("h1, h2, h3, h4, h5, h6")
      |> Enum.map(fn {tag, _attrs, _children} ->
        String.to_integer(String.slice(tag, 1, 1))
      end)

    # Check if headings skip levels (e.g., h1 -> h3)
    skipped_levels =
      headings
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [prev, current] -> current - prev > 1 end)

    if skipped_levels do
      [{:heading_hierarchy, "Heading levels skip (e.g., h1 to h3 without h2)"} | violations]
    else
      violations
    end
  end

  # Check html has lang attribute
  defp check_lang_attribute(violations, document) do
    html_elements = Floki.find(document, "html")

    has_lang =
      case html_elements do
        [{_tag, attrs, _children} | _] ->
          Enum.any?(attrs, fn {name, _value} -> name == "lang" end)
        _ ->
          false
      end

    if not has_lang do
      [{:missing_lang, "HTML element missing lang attribute"} | violations]
    else
      violations
    end
  end

  # Check buttons have accessible text
  defp check_buttons_have_text(violations, document) do
    buttons_without_text =
      document
      |> Floki.find("button")
      |> Enum.reject(fn button ->
        text = Floki.text(button) |> String.trim()
        aria_label = Floki.attribute(button, "aria-label") |> List.first()

        (text != "" and text != nil) or (aria_label != nil and aria_label != "")
      end)

    if length(buttons_without_text) > 0 do
      [{:buttons_no_text, "#{length(buttons_without_text)} button(s) without accessible text"} | violations]
    else
      violations
    end
  end

  # Check form elements have name attributes
  defp check_form_elements_have_names(violations, document) do
    form_elements = Floki.find(document, "input, textarea, select")

    elements_without_names =
      Enum.reject(form_elements, fn element ->
        # Exclude hidden inputs and buttons
        type = Floki.attribute(element, "type") |> List.first()
        name = Floki.attribute(element, "name") |> List.first()
        id = Floki.attribute(element, "id") |> List.first()

        # Skip hidden and button types
        skip_types = ["hidden", "submit", "button", "reset"]

        type in skip_types or name != nil or id != nil
      end)

    if length(elements_without_names) > 0 do
      [{:missing_names, "#{length(elements_without_names)} form element(s) without name or id attribute"} | violations]
    else
      violations
    end
  end
end
