/// Whether a box is a phone mounted sideways on the bars.
///
/// The cut is 1.8, not 1.4. A wide, short box is not a sideways phone: the
/// dashboard editor's preview is about 1.5 and has to keep the portrait
/// stack, because that is the shape the rider sees when the phone is upright.
bool isHandlebarLandscape(double width, double height) {
  if (height <= 0 || !width.isFinite || !height.isFinite) return false;
  return width > height * 1.8;
}
