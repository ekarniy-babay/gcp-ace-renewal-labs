#!/usr/bin/env python3
"""Apply Tasks 2.5 and 2.6 to the lab's chef.py (gs://spls/gsp517/chef.py): wine preference radio button and the chef prompt.

    python3 patch_chef.py chef.py
Fails loudly if the lab file no longer has the expected markers, instead of writing a half-patched file.
"""
import sys

WINE = '''
wine = st.radio(
    "What wine do you prefer?\\n\\n", ["Red", "White", "None"], key="wine", horizontal=True
)
'''

PROMPT = '''prompt = f"""I am a Chef. I need to create {cuisine} recipes for customers who want {dietary_preference} meals.
However, don't include recipes that use ingredients with the customer's {allergy} allergy.
I have {ingredient_1}, {ingredient_2} and {ingredient_3} in my kitchen and other ingredients.
The customer's wine preference is {wine}.
Please provide some meal recommendations.
For each recommendation include preparation instructions, time to prepare and the recipe title at the beginning of the response.
Then include the wine pairing for each recommendation.
At the end of the recommendation provide the calories associated with the meal and the nutritional facts.
"""'''

RADIO_ANCHOR = "# https://docs.streamlit.io/library/api-reference/widgets/st.radio\n"
OLD_PROMPT = 'prompt = f"""Why is the sky blue?"""'


def main(path):
    src = open(path, encoding="utf-8").read()
    if "key=\"wine\"" in src:
        print("chef.py already patched")
        return
    for marker in (RADIO_ANCHOR, OLD_PROMPT):
        if src.count(marker) != 1:
            sys.exit(f"STOP: marker not found exactly once in {path}: {marker.strip()!r}")
    src = src.replace(RADIO_ANCHOR, RADIO_ANCHOR + WINE).replace(OLD_PROMPT, PROMPT)
    open(path, "w", encoding="utf-8").write(src)
    print("chef.py patched: wine radio button (Task 2.5), chef prompt (Task 2.6)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "chef.py")
